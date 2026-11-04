import XCTest
@testable import DshMobile

/// 审计的判据：一次写操作一条记录，且客户端认得网关声明的每一个写 op。
///
/// 最要紧的是最后一条 —— 它守的是「网关新加了一个写 op，客户端没跟上」。那种漏法不会让
/// 任何行为判据变红：请求照常成功，只是这一端查不到自己做过什么。
final class AuditLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-audit-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func log() -> AuditLog {
        AuditLog(directory: directory)
    }

    private func entry(
        _ op: String = "session-prompt",
        target: String = "s-1",
        result: AuditResult = .ok,
        at: Date = Date(timeIntervalSince1970: 1_760_000_000),
        requestId: String? = nil
    ) -> AuditEntry {
        AuditEntry(at: at, op: op, target: target, result: result, requestId: requestId)
    }

    // MARK: - 一行的形状

    /// 解析器认得网关写出来的形状。
    ///
    /// 这条样本是**手写的固定值**，不经过本机的 formatter —— 两端各钉同一个样本，任何一端
    /// 改了格式，它自己会红。用 formatter 生成样本会让「两边都改了就都绿」。
    func testParsesTheShapeTheGatewayWrites() {
        let line = "2026-11-04T10:00:00.000+08:00 [audit] op=permission-select req=r-1 result=ok target=s-1"
        let parsed = AuditLine.parse(line)

        XCTAssertEqual(parsed?.op, "permission-select")
        XCTAssertEqual(parsed?.target, "s-1")
        XCTAssertEqual(parsed?.result, .ok)
        XCTAssertEqual(parsed?.requestId, "r-1")
    }

    func testARefusalKeepsItsCode() {
        let line = "2026-11-04T10:00:00.000+08:00 [audit] code=unknown-session op=session-prompt result=refused target=s-1"
        XCTAssertEqual(AuditLine.parse(line)?.result, .refused(code: "unknown-session"))
    }

    func testALineThatIsNotAnAuditRecordParsesToNothing() {
        // 半条记录读成一条比读不出来更坏 —— 猜出来的目标会指向错的地方。
        XCTAssertNil(AuditLine.parse("2026-11-04T10:00:00.000+08:00 [dsh][info][ws] something"))
        XCTAssertNil(AuditLine.parse(""))
        XCTAssertNil(AuditLine.parse("2026-11-04T10:00:00.000+08:00 [audit] op=x"))
    }

    func testAnEntryRoundTrips() {
        let original = entry(result: .refused(code: "unknown-session"), requestId: "r-2")
        XCTAssertEqual(AuditLine.parse(AuditLine.format(original)), original)
    }

    // MARK: - 落盘与读取

    func testEntriesLandInTheMonthTheyHappened() {
        let log = log()
        log.record(entry(at: Date(timeIntervalSince1970: 1_764_000_000)))  // 2025-11
        log.record(entry(at: Date(timeIntervalSince1970: 1_767_000_000)))  // 2026-01

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let months = Set(names.filter { $0.hasPrefix("audit-") })
        XCTAssertEqual(months.count, 2, "两个月的记录必须落在两个文件里：\(months.sorted())")
    }

    func testRecentWalksBackwardsAcrossMonths() {
        let log = log()
        log.record(entry(target: "first", at: Date(timeIntervalSince1970: 1_764_000_000)))
        log.record(entry(target: "second", at: Date(timeIntervalSince1970: 1_767_000_000)))

        XCTAssertEqual(log.recent(10).map(\.target), ["second", "first"])
        XCTAssertEqual(log.recent(1).map(\.target), ["second"])
    }

    func testRecentOnAMissingDirectoryIsEmpty() {
        // 审计目录在第一次写操作时才建。查询早于第一次写入时不该崩、也不该报错。
        let missing = AuditLog(directory: directory.appendingPathComponent("not-there"))
        XCTAssertEqual(missing.recent(5), [])
    }

    func testRecentZeroIsEmpty() {
        let log = log()
        log.record(entry())
        XCTAssertEqual(log.recent(0), [])
    }

    func testAWriteThatCannotLandIsSwallowed() {
        // 用一个文件占住目录路径：建目录会失败。记不下来不该让一次写操作失败 ——
        // 磁盘满时删工作空间失败，是比少一条审计更坏的交换。
        let blocker = directory.appendingPathComponent("blocked")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: blocker.path, contents: nil)

        let log = AuditLog(directory: blocker)
        log.record(entry())  // 不该崩
        XCTAssertEqual(log.recent(5), [])
    }

    // MARK: - 客户端的写请求覆盖网关声明的 op

    /// 客户端的 8 个写请求。它们都实现了 `AuditableRequest` —— 这一条是编译期的，
    /// 少了那个扩展，下面的类型转换会失败。
    private func writeRequests() -> [any GatewayRequest] {
        [
            SessionPromptRequest(sessionId: "s", text: "t", promptId: "p"),
            ApprovalAnswerRequest(eventId: "e", decision: "allow", answerId: "a"),
            CommandExecuteRequest(sessionId: "s", line: "/clear"),
            PermissionSelectRequest(sessionId: "s", preset: "accept-edits"),
            ModelSelectRequest(sessionId: "s", provider: "p", model: "m"),
            SessionCreateRequest(),
            WorkspaceCreateRequest(name: "proj"),
            WorkspaceDeleteRequest(workspaceId: "w"),
        ]
    }

    /// 网关声明的写 op 清单。读的是**网关的源码** —— 那是唯一真源。
    ///
    /// 不在这边再抄一份：抄一份就是两份事实，而它们漂移的那天没有任何东西会红。
    private func gatewayWriteOps() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // 仓库根
        let source = try String(contentsOf: root.appendingPathComponent("gateway/src/audit.ts"),
                                encoding: .utf8)

        guard let start = source.range(of: "WRITE_OPS = ["),
              let end = source.range(of: "] as const", range: start.upperBound..<source.endIndex)
        else { return [] }

        let body = String(source[start.upperBound..<end.lowerBound])
        let pattern = try NSRegularExpression(pattern: #"'([a-z][a-z-]+)'"#)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return Set(pattern.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        })
    }

    func testClientCoversEveryWriteOpTheGatewayDeclares() throws {
        let declared = try gatewayWriteOps()

        // 活性锚：一个都没读到说明路径或正则坏了 —— 那时「两边一致」只是因为两边都空。
        XCTAssertGreaterThanOrEqual(declared.count, 5, "只读到 \(declared.count) 个写 op —— 先怀疑路径")

        // 覆盖 = 有对应请求**且**它可审计。只看 op 名会放过「请求在、但没实现协议」——
        // 那正是「忘了加扩展」的形状，而它不会让任何别的判据变红。
        let covered = Set(writeRequests().compactMap { request -> String? in
            request is any AuditableRequest ? request.op : nil
        })
        let missing = declared.subtracting(covered)
        XCTAssertEqual(missing, [], "这些写 op 客户端没有可审计的请求：\(missing.sorted())")
    }

    func testEveryWriteRequestCarriesAnAuditTarget() {
        for request in writeRequests() {
            let auditable = request as? AuditableRequest
            XCTAssertNotNil(auditable, "\(request.op) 没实现 AuditableRequest —— 它的写操作不会留痕")
            XCTAssertNotEqual(auditable?.auditTarget, "", "\(request.op) 的审计目标不能是空串")
        }
    }

    /// 读请求**不该**实现 `AuditableRequest`：实现了就会在审计里留下一条什么都不改的记录，
    /// 而那会把「谁改了什么」稀释成「谁看过什么」。
    func testReadRequestsAreNotAuditable() {
        let reads: [any GatewayRequest] = [
            ModelCatalogRequest(),
            CommandCatalogRequest(sessionId: "s"),
            PermissionCatalogRequest(sessionId: "s"),
        ]
        for request in reads {
            XCTAssertNil(request as? AuditableRequest, "\(request.op) 是读 op，不该进审计")
        }
    }
}

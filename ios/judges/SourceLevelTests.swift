/**
 * 源码层面的几条判据 —— 读的是仓库里的文件，不是被测对象的状态。
 *
 * 它们住在判据 target 而不是测试 target：这些断言要的前提是「仓库在这台机器上」，
 * 而手机上没有这个前提。凡是能写成「某个源文件里不许出现某段文本」的，都归这里。
 *
 * 一半是「显示层不许内置业务字面量」：内置了就等于把网关或宿主的清单抄了一份，
 * 而那两份漂移时没有任何东西会红。另一半是「丢弃要留痕」：一段被丢掉的输入如果不留痕，
 * 屏幕上的「什么都没发生」与「这条路断了」长得一模一样。
 */
import Foundation
import XCTest

final class SourceLevelTests: XCTestCase {

    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // judges/
            .deletingLastPathComponent() // ios/
    }

    private var repoRoot: URL {
        iosRoot.deletingLastPathComponent()
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 打开一屏只有一个来源

    /// `SessionFollowing` 里没有「等了几秒就改走 HTTP」的兜底。
    ///
    /// 失败形态是两条来源各自算一份水位（「我读到 12」与「我读到 13」同时存在，而两者都
    /// 不报错）。第 2 期起打开帧是唯一来源，兜底连同 `readSnapshot` 一起删了 —— 这条判据
    /// 守的是它别以别的名字长回来。
    ///
    /// **判据是「没有第二条取数路」这件事本身**，所以扫的是「取数」的标记：
    ///
    /// - 快照读、那个闭包、以及 `Timer` **全目录禁**（它们只服务兜底）；流开关上再禁
    ///   HTTP 客户端（`RpcClient` / `readPage`）。
    /// - `Task.sleep` 只放行**合并窗口**那一种：参数写成 `*WindowNanos`（`RefreshGate` 的
    ///   批窗口、草稿同帧合并、权限目录合并），它们不取数，只是把一个渲染帧内的多次变化
    ///   并成一次重算。兜底那种「等几秒」写的是裸纳秒数，照样被抓。
    ///
    /// `start()` 必须在（正控：切块没切错）。
    func testTheSecondScreenNeverComesOverHTTP() throws {
        let root = iosRoot.appendingPathComponent("Sources/Features/SessionDetail/State")
        let files = Self.swiftFiles(under: root)
        // 活性锚：目录扫空了下面的差集也会「通过」。
        XCTAssertGreaterThan(files.count, 5, "只扫到 \(files.count) 个状态文件 —— 路径推算错了？")

        // 禁词分两档，因为「第二条取数路」在两个地方会长：
        //  ① 整个状态目录都不许出现 —— 快照读、那个闭包、`Timer`（它们只服务兜底）；
        //  ② 只有流开关不许出现 —— HTTP 客户端（`RpcClient` / `readPage`：翻页是读侧编排
        //     的事，流开关不该自己发请求）。
        // `Task.sleep` 单独判：只放行合并窗口（参数是 `*WindowNanos`），见下。
        let bannedEverywhere = ["readSnapshot", "syncNow", "Timer"]
        let bannedInFollowing = ["RpcClient", "readPage"]
        let windowSleep = "WindowNanos"

        var hits: [String] = []
        for file in files {
            let name = file.lastPathComponent
            let text = try read(file)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(line)
                for banned in bannedEverywhere where code.contains(banned) {
                    hits.append("\(name):\(number + 1) \(banned)")
                }
                // 定时器只放行合并窗口：裸纳秒数的 sleep 就是「等几秒」的兜底形态。
                if code.contains("Task.sleep") && !code.contains(windowSleep) {
                    hits.append("\(name):\(number + 1) Task.sleep 不是合并窗口")
                }
                if name == "SessionFollowing.swift" {
                    for banned in bannedInFollowing where code.contains(banned) {
                        hits.append("\(name):\(number + 1) \(banned)")
                    }
                }
            }
        }
        let following = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/State/SessionFollowing.swift"))
        XCTAssertTrue(following.contains("func start()"), "读到的不是流开关 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [],
                       "状态层里又出现了第二条取数路 —— 一屏只有一个来源")
    }

    // MARK: - 收帧链路只解一次

    /// 收帧链路上 `JSONDecoder(` 只出现在形状层，且只有一处。
    ///
    /// 守的是「同一份线上文本被解析两次」。**扫的是目录不是清单** —— 写死一份文件列表时，
    /// 往后在 `LongConnection/` 下新增一个文件（拆类型、加一层）默认就是绿的，判据形同虚设。
    /// 目录扫空了也不行（路径改名会让它一个文件都看不到，那等于什么都没测），所以先断言条数。
    func testTheInboundPathDecodesExactlyOnce() throws {
        let root = iosRoot.appendingPathComponent("Sources/Core/Gateway/LongConnection")
        let files = Self.swiftFiles(under: root)
        XCTAssertGreaterThan(files.count, 10, "扫到的文件太少，路径可能变了")

        var hits: [String: Int] = [:]
        for file in files {
            let relative = file.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
            let count = Self.codeLineCount(of: "JSONDecoder(", in: try read(file))
            if count > 0 { hits[relative] = count }
        }
        XCTAssertEqual(hits, ["Sources/Core/Gateway/LongConnection/Wire/MuxFrames.swift": 1],
                       "收帧链路上应只在形状层解一次，实际：\(hits)")

        // 判读层：进到这里的已经是解好的值，再解一次就是把成本原样加回来。
        for relative in ["Sources/Features/SessionDetail/State/SessionBehavior.swift",
                         "Sources/Features/SessionDetail/State/SessionStreamReader.swift",
                         "Sources/Core/Gateway/LongConnection/Stream/EventsStream.swift",
                         "Sources/Core/Gateway/LongConnection/Stream/ControlStream.swift"] {
            let count = Self.codeLineCount(
                of: "JSONDecoder(", in: try read(iosRoot.appendingPathComponent(relative))
            )
            XCTAssertEqual(count, 0, "\(relative)：判读层又自己解了一次字节")
        }
    }

    /// 数 `needle` 在**代码**里出现的次数。
    ///
    /// 三件事：跳过整行注释（判据本身就在若干条注释里写着这个符号）；削掉行尾注释
    /// （`let x = 1 // JSONDecoder(` 不该算实现）；按出现次数计而不是按行计
    /// （一行写两次只算一次，等于给了个绕过口）。
    ///
    /// 已知毛刺：字符串里含 `//` 的行会被提前截断。同一行既有 URL 又有解码调用的概率极低，
    /// 这里不为它加引号状态机。
    private static func codeLineCount(of needle: String, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) { count, line in
            let head = line.range(of: "//").map { line[..<$0.lowerBound] } ?? line
            let trimmed = head.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/*"), !trimmed.hasPrefix("*") else { return }
            count += String(head).components(separatedBy: needle).count - 1
        }
    }

    // MARK: - 显示层不许内置档名 / 命令名

    /// 这两个名字最可能被写成映射表的地方是显示层 —— 但它也可能被写进同屏的任何一处，
    /// 所以**扫整个界面目录**，不点名文件。点名清单的失败方式是「新增一个文件默认合规」，
    /// 与上面那条「扫目录不扫清单」的纪律相反。
    private var sessionDetailRoot: URL {
        iosRoot.appendingPathComponent("Sources/Features/SessionDetail")
    }

    /// 快照的可见节点与消息条数必须是存储值。
    ///
    /// 做成计算属性就是每读一次全量过滤一遍，而视图 body 每帧读三次 —— 代价看不见，
    /// 只有长会话里叠出来。这条判据认形态：`ChatSnapshot` 里不许有计算型的可见集。
    func testSnapshotKeepsItsVisibleHalfStored() throws {
        let file = iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/State/Conversation/ChatNode.swift")
        let code = try read(file)
        XCTAssertTrue(code.contains("struct ChatSnapshot"), "判据的落点没找对：\(file.path)")
        for (line, text) in Self.codeLines(in: code) {
            XCTAssertFalse(text.contains("var visible: [ChatNode] {"),
                           "\(file.lastPathComponent):\(line) 可见节点又变成计算属性了 —— 每帧全量过滤")
        }
    }

    func testMenuSourcesBakeInNoLevelNames() throws {
        let files = Self.swiftFiles(under: sessionDetailRoot)
        XCTAssertGreaterThan(files.count, 10, "只扫到 \(files.count) 个文件 —— 先怀疑路径推算")
        // 只认带引号的字面量：注释里提到 low/high 不算内置，所以逐代码行判。
        let baked = ["\"low\"", "\"high\"", "\"max\""]
        for file in files {
            for (line, code) in Self.codeLines(in: try read(file)) {
                for literal in baked where code.contains(literal) {
                    XCTFail("\(file.lastPathComponent):\(line) 内置了档名字面量 \(literal)")
                }
            }
        }
    }

    func testSlashSourcesBakeInNoCommandNames() throws {
        let files = Self.swiftFiles(under: sessionDetailRoot)
        XCTAssertGreaterThan(files.count, 10, "只扫到 \(files.count) 个文件 —— 先怀疑路径推算")
        let names = ["permission", "compact", "export", "goal", "plan", "feedback"]
        let baked = names.flatMap { ["\"/\($0)\"", "\"\($0)\""] }
        for file in files {
            // 逐**代码行**判，跳过注释：注释里点名某个命令正是为了说「别内置它」。
            for (line, code) in Self.codeLines(in: try read(file)) {
                for literal in baked where code.contains(literal) {
                    XCTFail("\(file.lastPathComponent):\(line) 内置了命令名字面量 \(literal)")
                }
            }
        }
    }

    // MARK: - 丢弃要留痕

    /// 留痕句必须落在一条 `Log.warn(` 调用上，**不是只出现在文件里**。
    ///
    /// 整文件 `contains` 的失败方式：删掉日志那一行、在注释里留同一句话（解释为什么记
    /// 这一行），判据照样绿 —— 而它是这条路径唯一的证据。
    func testCancelWithoutEventIdLeavesAVisibleTrace() throws {
        let lines = Self.codeLines(in: try read(iosRoot.appendingPathComponent(
            "Sources/Features/Approval/State/ApprovalStore.swift")))
        XCTAssertTrue(
            lines.contains { $0.1.contains("Log.warn(") && $0.1.contains("dropped a cancel without an eventId") },
            "留痕句不在了（或只剩注释）—— 无寻址撤回被丢弃时现场只剩这一行")
    }

    func testDroppedListChangeLeavesAVisibleTrace() throws {
        let lines = Self.codeLines(in: try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionList/State/SessionListState.swift")))
        // 留痕只留给**这一族里认不出**的那一条。少了前缀分流，`$events` 上那些别的
        // 命名空间（插件装卸、设置文档）会被当成「本版不认识的列表事件」刷警告。
        XCTAssertTrue(
            lines.contains { $0.1.contains("SessionListEvents.claims(") },
            "前缀分流不在了 —— 别的命名空间的事件会被当成坏增量")
        XCTAssertTrue(
            lines.contains {
                $0.1.contains("Log.warn(") && $0.1.contains("a session event this build cannot read")
            },
            "留痕句不在了（或只剩注释）—— 坏增量被丢弃时现场只剩这一行")
    }

    // MARK: - 票不落盘

    /// 产品层不许把接入票写进任何文件 —— 它是登记凭据，换出节点身份之后就没有用途了。
    ///
    /// 守的是「被人顺手加回来」：票存一次，下次启动就会拿一把可能早已作废的票去注册，
    /// 而它的失败会被误认成网络问题。与「日志出口唯一」同源：能被随手加回来的东西得有人看着。
    func testTheTicketIsNeverWrittenToDisk() throws {
        let sources = Self.swiftFiles(under: iosRoot.appendingPathComponent("Sources"))
        XCTAssertGreaterThan(sources.count, 50, "只扫到 \(sources.count) 个源文件 —— 先怀疑路径推算")

        for file in sources {
            let text = try read(file)
            XCTAssertFalse(text.contains("TailnetKeyStore"),
                           "\(file.lastPathComponent) 又出现了票的存储类型 —— 票不落盘")
            guard file.lastPathComponent != "TailnetNode.swift" else { continue }
            XCTAssertFalse(text.contains("tailnet-key"),
                           "\(file.lastPathComponent) 提到了票的文件名 —— 只有迁移时的删除允许")
        }

        // 唯一允许落在**代码**里的地方：把老版本留下的那份删掉的那一行。
        // 注释里提它是说明，不算数 —— 所以先滤掉注释行再数。
        let node = try read(iosRoot.appendingPathComponent("Sources/Core/MeshNetwork/TailnetNode.swift"))
        let hits = node.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
            return !isComment && line.contains("tailnet-key")
        }
        XCTAssertEqual(hits.count, 1, "票的文件名只该出现在「删掉老残留」那一行代码里")
        XCTAssertTrue(hits.first?.contains("legacyTicketFile") == true,
                      "提到它的那一行必须是为了删除，不是为了写入")
    }

    // MARK: - 行为测试不许读仓库

    /// `ios/tests/` 跑在设备或模拟器上，那里没有仓库路径。谁在那边按 `#filePath` 推算根，
    /// 谁就会在真机上一片红 —— 这条把那条边界钉住，不靠人记。
    func testBehaviorTestsDoNotReadTheRepository() throws {
        let testsRoot = iosRoot.appendingPathComponent("tests")
        let files = Self.swiftFiles(under: testsRoot)
        XCTAssertGreaterThan(files.count, 20, "只扫到 \(files.count) 个测试文件 —— 先怀疑路径推算")
        for file in files {
            let text = try read(file)
            XCTAssertFalse(text.contains("fileURLWithPath: #filePath"),
                           "\(file.lastPathComponent) 按 #filePath 推算仓库根 —— 手机上读不到，"
                           + "这类断言属于判据 target")
        }
    }

    // MARK: - 网关声明的写 op 都要有可审计的客户端请求

    /// 客户端这一侧由**类型**表达：实现了 `AuditableRequest` 就是一次写操作，不再维护 op 名单。
    /// 所以这里从源码取两样 —— 哪些请求类型实现了那个协议、以及它们的端点名（`endpoint`）。
    ///
    /// **活性锚不用常量**：常量总落后于表（写 8 的时候表里已经有 9 条），落后一格恰好让
    /// 「漏读一个写端点」变成绿 —— 而那正是这条判据要抓的。这里直接数表里的 `write: true`
    /// 与客户端的 `extension …: AuditableRequest`，两边的解析结果必须与各自的标志数相等，
    /// 正则漏一条就当场对不上。
    func testClientCoversEveryWriteEndpointTheGatewayDeclares() throws {
        let declared = try gatewayWriteEndpoints()
        let flags = try gatewayWriteFlagCount()
        XCTAssertEqual(declared.count, flags,
                       "解析出 \(declared.count) 个写端点，表里有 \(flags) 处 `write: true` —— 正则漏了条目")
        // 下限随端点增减改这一处：它守的是「表里没有多出来的空号」，不是某个具体数量。
        // 当前 7 个 —— 第 3 期把两条应答端点换成了一条 `$events/result`。
        XCTAssertGreaterThanOrEqual(declared.count, 7,
                                    "只读到 \(declared.count) 个写端点 —— 先怀疑路径或正则")

        let covered = try auditableClientEndpoints()
        let extensions = try auditableExtensionCount()
        XCTAssertEqual(covered.count, extensions,
                       "客户端有 \(extensions) 处 `AuditableRequest`，只解析出 \(covered.count) 个端点名 —— "
                       + "先怀疑请求类型的正则")
        XCTAssertGreaterThanOrEqual(covered.count, 7,
                                    "只读到 \(covered.count) 个可审计端点 —— 先怀疑解析")

        let missing = declared.subtracting(covered)
        XCTAssertEqual(missing, [], "这些写端点客户端没有可审计的请求：\(missing.sorted())")
        // 反向：客户端记了审计、网关却当读端点的那些 —— 那会让「谁改了什么」多出
        // 一条什么都不改的记录，而它比漏记更难发现（审计看起来更"全"了）。
        let extra = covered.subtracting(declared)
        XCTAssertEqual(extra, [], "这些端点在客户端会留痕、但网关声明成读：\(extra.sorted())")
    }

    /// 网关声明的**写端点**清单。读的是端点表 —— 那是唯一判定处（`write: true` 那一格）。
    ///
    /// 一期之前这里读的是 `audit.ts` 的 `WRITE_OPS`；信封改造把那份清单删了，
    /// 判定只剩端点表一处。名字从旧 op 名换成了端点名 —— 判据两边都换，否则它读空。
    private func gatewayWriteEndpoints() throws -> Set<String> {
        let source = try read(repoRoot.appendingPathComponent(
            "gateway/src/protocol/unary-endpoints.ts"))
        let pattern = try NSRegularExpression(
            pattern: #"'([^'\s]+/[^'\s]+)':\s*\{\s*legacyOp:\s*'[^']*',\s*write:\s*(true|false)"#)
        let range = NSRange(source.startIndex..., in: source)
        var writes = Set<String>()
        for match in pattern.matches(in: source, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let flagRange = Range(match.range(at: 2), in: source) else { continue }
            if source[flagRange] == "true" { writes.insert(String(source[nameRange])) }
        }
        return writes
    }

    /// 端点表里 `write: true` 的条数 —— 与 `gatewayWriteEndpoints()` 互为活性锚。
    ///
    /// 只认**行首**的 `write: true`：表里每条端点的这个标志都独占一行。写法变了（挪到别的
    /// 字段后面、写成别的形状）时这里会少数，于是与解析结果对不上而红 —— 报的是
    /// 「先看标志的写法」，不是静默放过。
    private func gatewayWriteFlagCount() throws -> Int {
        let source = try read(repoRoot.appendingPathComponent(
            "gateway/src/protocol/unary-endpoints.ts"))
        return Self.codeLines(in: source).filter {
            $0.1.trimmingCharacters(in: .whitespaces)
                .range(of: #"^write:\s*true\b"#, options: .regularExpression) != nil
        }.count
    }

    /// 客户端可审计的**端点**名：请求类型实现了 `AuditableRequest`，且它的 `endpoint`
    /// 是个字面量（`static let endpoint = "…"`）。
    private func auditableClientEndpoints() throws -> Set<String> {
        let messages = try read(iosRoot.appendingPathComponent(
            "Sources/Core/Gateway/Rpc/Wire/RpcMessages.swift"))

        var endpointByType: [String: String] = [:]
        let structPattern = try NSRegularExpression(
            pattern: #"struct\s+(\w+)\s*:\s*GatewayRequest\b[^\n{]*\{([\s\S]*?)\n\}"#)
        let range = NSRange(messages.startIndex..., in: messages)
        for match in structPattern.matches(in: messages, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: messages),
                  let bodyRange = Range(match.range(at: 2), in: messages) else { continue }
            let body = String(messages[bodyRange])
            guard let endpoint = Self.literals(in: body, pattern: #"static let endpoint = "([^"]+)""#).first
            else { continue }
            endpointByType[String(messages[nameRange])] = endpoint
        }

        var auditable = Set<String>()
        for file in Self.swiftFiles(under: iosRoot.appendingPathComponent("Sources")) {
            guard let text = try? read(file) else { continue }
            auditable.formUnion(Self.literals(in: text, pattern: #"extension\s+(\w+)\s*:\s*AuditableRequest"#))
        }
        return Set(auditable.compactMap { endpointByType[$0] })
    }

    /// 源码里 `extension …: AuditableRequest` 的条数 —— 与解析出的端点数互为活性锚。
    private func auditableExtensionCount() throws -> Int {
        var count = 0
        for file in Self.swiftFiles(under: iosRoot.appendingPathComponent("Sources")) {
            guard let text = try? read(file) else { continue }
            count += Self.literals(in: text, pattern: #"extension\s+(\w+)\s*:\s*AuditableRequest"#).count
        }
        return count
    }

    private static func literals(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// 代码行：跳过整行注释（`//` / `*` / `/*` 开头）。行内注释不剥 —— 与其余判据同一口径。
    private static func codeLines(in text: String) -> [(Int, String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    return nil
                }
                return (index + 1, String(line))
            }
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}

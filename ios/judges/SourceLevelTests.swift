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
                         "Sources/Core/Gateway/Events/EventReader.swift",
                         "Sources/Core/Gateway/Events/EventStream.swift"] {
            let count = Self.codeLineCount(
                of: "JSONDecoder(", in: try read(iosRoot.appendingPathComponent(relative))
            )
            XCTAssertEqual(count, 0, "\(relative)：判读层又自己解了一次字节")
        }
    }

    /// 目录下所有 `.swift`。`enumerator` 不是递归手写，符号链接与深目录都由它处理。
    private static func swiftFiles(under dir: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
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

    func testMenuSourcesBakeInNoLevelNames() throws {
        let sources = iosRoot.appendingPathComponent("Sources/Features/SessionDetail")
        let files = [
            sources.appendingPathComponent("State/ModelMenu.swift"),
            sources.appendingPathComponent("Views/ModelPickerView.swift"),
            sources.appendingPathComponent("Views/ModelSheetView.swift"),
            // 档名→字这件事最可能被写成映射表的地方，正是显示层 —— 它必须一起扫。
            sources.appendingPathComponent("Display/CatalogText.swift"),
        ]
        // 只认带引号的字面量：注释里提到 low/high 不算内置。
        let baked = ["\"low\"", "\"high\"", "\"max\""]
        for file in files {
            let text = try read(file)
            for literal in baked {
                XCTAssertFalse(text.contains(literal), "\(file.lastPathComponent) 内置了档名字面量 \(literal)")
            }
        }
    }

    func testSlashSourcesBakeInNoCommandNames() throws {
        let sources = iosRoot.appendingPathComponent("Sources/Features/SessionDetail")
        let files = [
            sources.appendingPathComponent("State/SlashTrigger.swift"),
            sources.appendingPathComponent("State/CommandDirectory.swift"),
            sources.appendingPathComponent("Views/CommandPalette.swift"),
            sources.appendingPathComponent("Views/CommandRow.swift"),
        ]
        let names = ["permission", "compact", "export", "goal", "plan", "feedback"]
        let baked = names.flatMap { ["\"/\($0)\"", "\"\($0)\""] }
        for file in files {
            let text = try read(file)
            // 逐**代码行**判，跳过注释：注释里点名某个命令正是为了说「别内置它」，
            // 整段 `contains` 会把那种说明当成内置。
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("/*"), !code.hasPrefix("*") else { continue }
                for literal in baked where code.contains(literal) {
                    XCTFail("\(file.lastPathComponent):\(index + 1) 内置了命令名字面量 \(literal)")
                }
            }
        }
    }

    // MARK: - 丢弃要留痕

    func testCancelWithoutEventIdLeavesAVisibleTrace() throws {
        let source = try read(iosRoot.appendingPathComponent(
            "Sources/Features/Approval/State/ApprovalStore.swift"))
        XCTAssertTrue(source.contains("dropped a cancel without an eventId"),
                      "留痕句不在了 —— 无寻址撤回被丢弃时现场只剩这一行")
    }

    func testDroppedListChangeLeavesAVisibleTrace() throws {
        let source = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionList/State/SessionListState.swift"))
        XCTAssertTrue(source.contains("dropped a session-list change this build does not know"),
                      "留痕句不在了 —— 坏增量被丢弃时现场只剩这一行")
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
    /// 所以这里从源码取两样 —— 哪些请求类型实现了那个协议、以及它们的 `op` 字面量。
    ///
    /// 两处活性锚是必须的：取到 0 个时「两边一致」只说明两边都空。
    func testClientCoversEveryWriteOpTheGatewayDeclares() throws {
        let declared = try gatewayWriteOps()
        XCTAssertGreaterThanOrEqual(declared.count, 5,
                                    "只读到 \(declared.count) 个写 op —— 先怀疑路径或正则")

        let covered = try auditableClientOps()
        XCTAssertGreaterThanOrEqual(covered.count, 5,
                                    "只读到 \(covered.count) 个可审计请求 —— 先怀疑解析")

        let missing = declared.subtracting(covered)
        XCTAssertEqual(missing, [], "这些写 op 客户端没有可审计的请求：\(missing.sorted())")
    }

    /// 网关的写 op 清单。读的是网关源码 —— 那是唯一真源。
    private func gatewayWriteOps() throws -> Set<String> {
        let source = try read(repoRoot.appendingPathComponent("gateway/src/audit.ts"))
        guard let start = source.range(of: "WRITE_OPS = ["),
              let end = source.range(of: "] as const", range: start.upperBound..<source.endIndex)
        else { return [] }
        let body = String(source[start.upperBound..<end.lowerBound])
        return Set(Self.literals(in: body, pattern: #"'([a-z][a-z-]+)'"#))
    }

    /// 客户端可审计的 op：请求类型实现了 `AuditableRequest`，且它的 `op` 是个字面量。
    private func auditableClientOps() throws -> Set<String> {
        let messages = try read(iosRoot.appendingPathComponent(
            "Sources/Core/Gateway/Rpc/Wire/RpcMessages.swift"))

        var opsByType: [String: String] = [:]
        let structPattern = try NSRegularExpression(
            pattern: #"struct\s+(\w+)\s*:\s*GatewayRequest\s*\{([\s\S]*?)\n\}"#)
        let range = NSRange(messages.startIndex..., in: messages)
        for match in structPattern.matches(in: messages, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: messages),
                  let bodyRange = Range(match.range(at: 2), in: messages) else { continue }
            let body = String(messages[bodyRange])
            guard let op = Self.literals(in: body, pattern: #"let op = "([^"]+)""#).first else { continue }
            opsByType[String(messages[nameRange])] = op
        }

        var auditable = Set<String>()
        for file in Self.swiftFiles(under: iosRoot.appendingPathComponent("Sources")) {
            guard let text = try? read(file) else { continue }
            auditable.formUnion(Self.literals(in: text, pattern: #"extension\s+(\w+)\s*:\s*AuditableRequest"#))
        }
        return Set(auditable.compactMap { opsByType[$0] })
    }

    private static func literals(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}

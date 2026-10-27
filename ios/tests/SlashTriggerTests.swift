/**
 * 斜杠触发与命令过滤 —— 「这行字在敲命令吗」与「有哪些命令可选」。
 *
 * 判据只喂草稿字符串与命令数组，不碰网络、不碰视图。期望值一律手写：
 * 从实现反推的期望等于没测。
 *
 * 最后一条是源码扫描：客户端不得内置任何命令名（真实命令名只能来自宿主）。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class SlashTriggerTests: XCTestCase {

    // MARK: - O1 触发边界的四种形态

    /// 刚敲一个斜杠 → 查询串为空（列全部）；继续打字 → 查询串是那一段；
    /// **含空白 → 不算在敲命令**（用户已经进到参数里，面板该收起）；
    /// 不在开头 → 不算（普通消息里的 `/` 是路径或分数）。
    func testTriggerBoundary() {
        XCTAssertEqual(SlashTrigger.of(draft: "/"), .querying(""), "刚敲斜杠：查询为空，列全部")
        XCTAssertEqual(SlashTrigger.of(draft: "/per"), .querying("per"), "继续打字：查询是斜杠后那一段")
        XCTAssertEqual(SlashTrigger.of(draft: "/permission "), .inactive,
                       "含空白 = 已经在写参数，面板收起（再弹着候选会挡住用户写字）")
        XCTAssertEqual(SlashTrigger.of(draft: "/permission read-only"), .inactive, "带参数的行同样不算在敲命令")
        XCTAssertEqual(SlashTrigger.of(draft: "hello /"), .inactive, "斜杠不在开头：普通消息，不是命令")
        XCTAssertEqual(SlashTrigger.of(draft: "看下 src/Core 目录"), .inactive, "路径里的斜杠不是命令")
        XCTAssertEqual(SlashTrigger.of(draft: ""), .inactive, "空草稿")
    }

    // MARK: - O2 回填

    /// 选中一条之后一律补尾空格：命令名之后的那个分隔符是宿主语法的一部分，
    /// 补上它用户才能接着写参数；无参数命令多一个空格无害（宿主的 rawInput 会 trim）。
    func testInsertAlwaysLeavesRoomForArguments() {
        XCTAssertEqual(SlashTrigger.insert(name: "permission"), "/permission ")
        XCTAssertEqual(SlashTrigger.insert(name: "compact"), "/compact ")
        // 回填出来的草稿必须已经「不在敲命令」——否则面板会盖住刚填好的那一行。
        XCTAssertEqual(SlashTrigger.of(draft: SlashTrigger.insert(name: "permission")), .inactive)
    }

    // MARK: - O3 过滤

    private func commands() -> [CommandInfo] {
        [
            CommandInfo(name: "compact", description: "Compact the conversation"),
            CommandInfo(name: "permission", description: "Switch the permission preset", inputHint: "<preset>"),
            CommandInfo(name: "export", description: "Export the session log"),
        ]
    }

    // MARK: - O6 分流（决定这行字上 Mac 执行还是发给模型）

    /// 归一化之后以 `/` 开头 → 命令；否则 → 消息。三条边界与面板的判定同源。
    func testDispatchRoutesSlashLinesToCommandsOnly() {
        XCTAssertEqual(SlashTrigger.dispatch(of: "/permission read-only"),
                       .command("/permission read-only"), "带参数也整行交给宿主")
        XCTAssertEqual(SlashTrigger.dispatch(of: "/compact"), .command("/compact"))
        XCTAssertEqual(SlashTrigger.dispatch(of: "hello"), .prompt("hello"))
        XCTAssertEqual(SlashTrigger.dispatch(of: "看下 src/Core 目录"),
                       .prompt("看下 src/Core 目录"), "路径里的斜杠不是命令")
    }

    /// 面板与分流必须看**同一份**输入 —— 这是本期最容易分叉的一处。
    ///
    /// `" /permission"`（前导空格）归一化之后是 `/permission`。两处若各读一份原始草稿：
    /// 面板判「不在敲命令」（不弹候选、也不重拉），发送却判「是命令」—— 用户看不到任何候选，
    /// 却执行了一条命令。所以这里断言的是「同一份归一化结果喂给两边，结论不矛盾」。
    func testPaletteAndDispatchReadTheSameNormalizedText() {
        for draft in ["/per", " /permission", "/permission read-only", "hello", " /hello"] {
            let normalized = PromptDraft.normalized(draft) ?? ""
            let route = SlashTrigger.dispatch(of: normalized)
            switch SlashTrigger.of(draft: normalized) {
            case .querying:
                XCTAssertEqual(route, .command(normalized),
                               "面板在敲命令 \(draft) → 这一行必须走命令通道")
            case .inactive:
                // 面板收起不代表不是命令（带参数的行就是），但「不是命令」时必须一致。
                if case .command = route {
                    XCTAssertTrue(normalized.hasPrefix("/"),
                                  "面板说不在敲命令、发送说走命令，只有「带参数的命令行」这一种")
                }
            }
        }
        XCTAssertEqual(PromptDraft.normalized(" /permission"), "/permission",
                       "归一化会去掉前导空白 —— 两边都读它才不会分叉")
    }

    // MARK: - O2b 参数占位

    /// 候选行上的「怎么用」：宿主给了 `input.hint` 就带上它，没有就只给名字。
    ///
    /// 判据要能区分两条命令：只断言「非空」的话，把 hint 丢掉仍然绿。
    func testInvocationCarriesTheHostHint() {
        let withHint = commands().first { $0.name == "permission" }
        XCTAssertEqual(withHint?.invocation, "/permission <preset>", "有 hint：名字 + 占位")

        let withoutHint = commands().first { $0.name == "compact" }
        XCTAssertEqual(withoutHint?.invocation, "/compact", "没有 hint：不凭空编一个参数")

        XCTAssertEqual(CommandInfo(name: "x", description: "", inputHint: "").invocation, "/x",
                       "空串的 hint 等同没有 —— 不要留一个悬空空格")
    }

    /// 空查询返回全部（宿主给的顺序）；前缀匹配优先于包含匹配；大小写不敏感。
    func testMatchRanksPrefixBeforeContains() {
        XCTAssertEqual(CommandDirectory.match(commands(), query: "").map(\.name),
                       ["compact", "permission", "export"], "空查询：全部，保持宿主顺序")

        XCTAssertEqual(CommandDirectory.match(commands(), query: "PER").map(\.name),
                       ["permission"], "大小写不敏感")

        // 构造一条「前缀命中优先于包含命中」的例子。
        let ordered = [CommandInfo(name: "restore", description: ""), CommandInfo(name: "store", description: "")]
        XCTAssertEqual(CommandDirectory.match(ordered, query: "st").map(\.name),
                       ["store", "restore"], "前缀命中排在包含命中之前")
    }

    /// 过滤只看名字，不看说明 —— 说明是给人读的一句话，拿它参与匹配会让「敲了 per 却命中
    /// 一条名字完全无关的命令」变成常态。
    func testMatchIgnoresDescription() {
        let withDescription = [CommandInfo(name: "compact", description: "permission related cleanup")]
        XCTAssertEqual(CommandDirectory.match(withDescription, query: "per").map(\.name), [],
                       "说明里的词不该把命令捞出来")
    }

    // MARK: - O4 三面

    /// 未取过 = 等待面（不是空列表）；取到空数组 = 成功面（这个会话真没有命令）；
    /// 失败带原因。三者屏幕上的说法不同，判定必须分开。
    func testOutcomeFaces() async {
        let waiting = CommandDirectory(fetch: { self.commands() })
        XCTAssertEqual(waiting.outcome, .waiting, "还没取过：等待面")

        let empty = CommandDirectory(fetch: { [] })
        await empty.reload()
        XCTAssertEqual(empty.outcome, .ready([]), "空数组是成功面，不是等待")

        let refused = CommandDirectory(fetch: { throw RpcClientError.notActivated })
        await refused.reload()
        XCTAssertEqual(refused.outcome, .failed(.offline), "传输失败 → 离线面")
    }

    // MARK: - O6 客户端不内置命令名

    /// 三个命令相关源文件里不得出现真实命令名的字面量（`"/permission"` 之类）——
    /// 名字只能来自宿主，否则新增一条命令要改客户端。
    ///
    /// 表收宿主内置的全部命令名，两种引号形态各一条：`"/x"`（整行）与 `"x"`（裸名）。
    func testSourcesBakeInNoCommandNames() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/SessionDetail")
        let files = [
            sources.appendingPathComponent("State/SlashTrigger.swift"),
            sources.appendingPathComponent("State/CommandDirectory.swift"),
            sources.appendingPathComponent("Views/CommandPalette.swift"),
            sources.appendingPathComponent("Views/CommandRow.swift"),
        ]
        let names = ["permission", "compact", "export", "goal", "plan", "feedback"]
        let baked = names.flatMap { ["\"/\($0)\"", "\"\($0)\""] }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
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
}

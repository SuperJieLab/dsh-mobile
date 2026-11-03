/**
 * 会话详情组装器的测试（A1–A9、切片 S1–S5）：纯状态机，不 import SwiftUI / UIKit、不碰网络与磁盘。
 *
 * 两段：**A 类**喂定死的事件；
 * **切片**（`sliceChecks`）编进镜像让窗口动起来（打开 / 往回翻 / 冷启动重取）。
 *
 * 配对与状态判定照**运行时产物**
 * （`@deepseek-ai/dsh-client-ui-chat`）：
 * - 配对 id = `tool/call.data.callId` ↔ `tool/result.data.message.source.callId`
 * - 失败标记 = `tool/result.data.message.isError`（**不是** `content[0].isError` —— clone 仓库版本
 *   落后于运行时，实测日志里前者有值、后者从不出现）
 * - 中断 = 所在 step / turn 已关闭，而这条 call 一直没有结果
 */
import Foundation
import XCTest

@testable import DshMobile

final class TranscriptAssemblerTests: XCTestCase {

    /// 从线的形状直接造一条事件（事件体原样透传）。
    private func event(_ json: String) -> SessionEvent {
        do {
            return try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        } catch {
            fatalError("测试事件解不出来：\(error)\n\(json)")
        }
    }

    /// 组装一段事件，同时收下「上报的不认识类型」。
    private func assemble(_ json: [String]) -> (nodes: [TranscriptNode], unknown: [String]) {
        var unknown: [String] = []
        var assembler = TranscriptAssembler(onUnknownEventType: { unknown.append($0) })
        return (assembler.assemble(json.map(event)), unknown)
    }

    /// 把节点里的工具行摊平出来（断言不关心折叠结构）。
    private func toolRows(in nodes: [TranscriptNode]) -> [ToolRow] {
        nodes.flatMap { node -> [ToolRow] in
            guard case .process(let process) = node else { return [] }
            return process.entries.compactMap { entry in
                if case .tool(let row) = entry { return row }
                return nil
            }
        }
    }

    private func processes(in nodes: [TranscriptNode]) -> [NodeProcess] {
        nodes.compactMap { node in
            if case .process(let process) = node { return process }
            return nil
        }
    }

    private func messages(in nodes: [TranscriptNode]) -> [DisplayMessage] {
        nodes.compactMap { node in
            if case .message(let message) = node { return message }
            return nil
        }
    }

    private let call = #"{"type":"tool/call","seq":11,"time":110,"data":{"turn":1,"step":1,"callId":"c1","name":"bash","arguments":"{\"command\": \"pwd && ls -la\", \"description\": \"List workspace contents\"}"}}"#

    private func result(seq: Int, isError: Bool = false, text: String = "total 8") -> String {
        #"{"type":"tool/result","seq":\#(seq),"time":\#(seq * 10),"data":{"turn":1,"step":1,"message":{"role":"tool","source":{"kind":"tool","callId":"c1"},"toolCallId":"c1","content":[{"type":"text","text":"\#(text)"}],"isError":\#(isError),"id":"m1"}}}"#
    }

    /// 摘要缓存不改变输出：同一个组装器连跑两次，节点逐条相等。
    ///
    /// 缓存是性能改动 —— 每次刷新都重放整段窗口，不缓存就要把历史里每个工具调用的参数
    /// 重新解一遍 JSON，越翻越慢。这条守的是「它只省了重复计算，没改任何一条判定」。
    func testAssemblyIsStableAcrossRuns() {
        let json = [
            #"{"type":"turn/start","seq":10,"time":100,"data":{"turn":1}}"#,
            call,
            result(seq: 12),
            #"{"type":"turn/end","seq":13,"time":130,"data":{"turn":1,"reason":{"kind":"completed"}}}"#,
        ]
        var assembler = TranscriptAssembler()
        let first = assembler.assemble(json.map(event))
        let second = assembler.assemble(json.map(event))
        XCTAssertFalse(first.isEmpty, "先确认这一批产出了节点 —— 不然「相等」是空的相等")
        XCTAssertEqual(first, second)
    }

    func testTranscript() {
        // A1：一组 call + result（同 callId、isError 假）→ 一行「成功」，
        // 摘要取参数里的 description（上游候选键里排在 command 之前）。
        var report = assemble([
            #"{"type":"turn/start","seq":10,"time":100,"data":{"turn":1}}"#,
            call,
            result(seq: 12),
            #"{"type":"turn/end","seq":13,"time":130,"data":{"turn":1,"reason":{"kind":"completed"}}}"#,
        ])
        var rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.count == 1, "A1a 一对 call/result 出一行")
        XCTAssertTrue(rows.first?.status == .succeeded, "A1b isError 假 → 成功")
        XCTAssertTrue(rows.first?.name == "bash", "A1c 工具名取自 call")
        XCTAssertTrue(rows.first?.summary == "List workspace contents", "A1d 摘要取候选键里靠前的 description")
        XCTAssertTrue(rows.first?.argumentsRaw?.isEmpty == false, "A1e 原始参数留给展开看")
        XCTAssertTrue(rows.first?.resultText == "total 8", "A1f 结果正文留给展开看")
        XCTAssertTrue(rows.first?.errorCode == nil, "A1g 成功不报错")

        // A1 的兜底：候选键都没命中时回落工具名。
        report = assemble([
            #"{"type":"tool/call","seq":20,"time":200,"data":{"turn":2,"step":1,"callId":"c2","name":"glob","arguments":"{\"other\": 1}"}}"#,
            #"{"type":"tool/result","seq":21,"time":210,"data":{"turn":2,"step":1,"message":{"role":"tool","source":{"kind":"tool","callId":"c2"},"content":[{"type":"text","text":"ok"}],"isError":false,"id":"m2"}}}"#,
        ])
        rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.first?.summary == "glob", "A1h 参数里没有可读键时回落工具名")

        // A2a：只有 call（没有 result）→ 「运行中」，不假装有结果。
        report = assemble([call])
        rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.first?.status == .running, "A2a 只有 call → 运行中")
        XCTAssertTrue(rows.first?.resultText == nil, "A2b 没有结果就不给结果")

        // A2b：只有 result（call 在窗口外）→ 出工具行但不假装有参数。
        report = assemble([result(seq: 30)])
        rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.count == 1, "A2c 只有 result 也出一行（不丢）")
        XCTAssertTrue(rows.first?.status == .succeeded, "A2d 只有 result 时状态仍由 isError 定")
        XCTAssertTrue(rows.first?.name == nil, "A2e 不知道工具名就不编一个")
        XCTAssertTrue(rows.first?.argumentsRaw == nil, "A2f call 不在窗口里就不假装有参数")

        // A3：轮次关闭而 call 没有结果 → 「中断」，不是永远「运行中」。
        report = assemble([
            #"{"type":"turn/start","seq":40,"time":400,"data":{"turn":3}}"#,
            #"{"type":"tool/call","seq":41,"time":410,"data":{"turn":3,"step":1,"callId":"c3","name":"bash","arguments":"{}"}}"#,
            #"{"type":"step/end","seq":42,"time":420,"data":{"turn":3,"step":1}}"#,
        ])
        rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.first?.status == .interrupted, "A3a step 关闭而 call 无结果 → 中断")

        report = assemble([
            #"{"type":"turn/start","seq":50,"time":500,"data":{"turn":4}}"#,
            #"{"type":"tool/call","seq":51,"time":510,"data":{"turn":4,"step":1,"callId":"c4","name":"bash","arguments":"{}"}}"#,
            #"{"type":"turn/end","seq":52,"time":520,"data":{"turn":4,"reason":{"kind":"completed"}}}"#,
        ])
        rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.first?.status == .interrupted, "A3b turn 关闭而 call 无结果 → 中断")

        // A3 的反面：轮次没关就还是「运行中」—— 中断不能提前发生。
        report = assemble([
            #"{"type":"turn/start","seq":60,"time":600,"data":{"turn":5}}"#,
            #"{"type":"tool/call","seq":61,"time":610,"data":{"turn":5,"step":1,"callId":"c5","name":"bash","arguments":"{}"}}"#,
        ])
        rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.first?.status == .running, "A3c 轮次未关闭时仍是运行中")

        // A4：isError 真 → 「失败」，与 A1 的成功同一判定来源。
        report = assemble([
            call,
            #"{"type":"tool/result","seq":71,"time":710,"data":{"turn":1,"step":1,"message":{"role":"tool","source":{"kind":"tool","callId":"c1"},"content":[{"type":"text","text":"timeout"}],"isError":true,"id":"m3"},"error":{"name":"ToolTimeoutError","code":"TOOL_TIMEOUT"}}}"#,
        ])
        rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.first?.status == .failed, "A4a isError 真 → 失败")
        XCTAssertTrue(rows.first?.errorCode == "TOOL_TIMEOUT", "A4b 上游给的错误码照原样带上")
        XCTAssertTrue(rows.first?.resultText == "timeout", "A4c 失败也有正文")

        // A8：一条不认识的 type 夹在已知事件之间。
        let known: [String] = [
            #"{"type":"turn/start","seq":80,"time":800,"data":{"turn":6}}"#,
            call,
            result(seq: 82),
            #"{"type":"turn/end","seq":83,"time":830,"data":{"turn":6,"reason":{"kind":"completed"}}}"#,
        ]
        let withoutIt = assemble(known)
        let withIt = assemble([
            #"{"type":"turn/start","seq":80,"time":800,"data":{"turn":6}}"#,
            call,
            #"{"type":"future/streaming-thing","seq":84,"time":840,"data":{"anything":true}}"#,
            result(seq: 82),
            #"{"type":"turn/end","seq":83,"time":830,"data":{"turn":6,"reason":{"kind":"completed"}}}"#,
        ])
        XCTAssertTrue(withIt.nodes == withoutIt.nodes, "A8a 不认识的类型不改变组装结果，也不崩")
        XCTAssertTrue(withoutIt.unknown.isEmpty, "A8b 没有新类型时不上报")
        XCTAssertTrue(withIt.unknown == ["future/streaming-thing"], "A8c 上报一次该类型")

        // A8 的补充：同一类型再来不重复上报（每次打开会话都会重放整段窗口）。
        let repeats = assemble([
            #"{"type":"future/streaming-thing","seq":90,"time":900,"data":{}}"#,
            #"{"type":"future/streaming-thing","seq":91,"time":910,"data":{}}"#,
            #"{"type":"future/other","seq":92,"time":920,"data":{}}"#,
        ])
        XCTAssertTrue(repeats.unknown == ["future/streaming-thing", "future/other"], "A8d 按类型去重")

        // A8 的另一面：已知但归别的链路管的事件不该被当成「上游加了新东西」。
        let bypass = assemble([
            #"{"type":"approval/asked","seq":95,"time":950,"data":{"id":"a1","toolName":"bash"}}"#,
            #"{"type":"request/context","seq":96,"time":960,"data":{}}"#,
            #"{"type":"web/deepseek-search-llm-request","seq":97,"time":970,"data":{}}"#,
            #"{"type":"agent/inbox/spliced","seq":98,"time":980,"data":{}}"#,
        ])
        XCTAssertTrue(bypass.unknown.isEmpty, "A8e 已知旁路类型不上报")

        // 用户消息仍然照常出消息节点（组装器不吞掉既有能力）。
        let user = assemble([
            #"{"type":"user/message","seq":100,"time":1000,"data":{"role":"user","source":{"kind":"user"},"content":[{"type":"text","text":"这里面有什么内容"}]}}"#,
        ])
        XCTAssertTrue(messages(in: user.nodes).first?.text == "这里面有什么内容", "用户消息照常成节点")

        // A7a：`turn/start` 在窗口里 → 这一组有头（可以画折叠头）。
        let headed = assemble([
            #"{"type":"turn/start","seq":110,"time":1100,"data":{"turn":11}}"#,
            #"{"type":"tool/call","seq":111,"time":1110,"data":{"turn":11,"step":1,"callId":"c7","name":"bash","arguments":"{}"}}"#,
            #"{"type":"turn/end","seq":112,"time":1120,"data":{"turn":11,"reason":{"kind":"completed"}}}"#,
        ])
        XCTAssertTrue(processes(in: headed.nodes).first?.hasHeader == true, "A7a 有 turn/start → 这一组有头")

        // A7b：窗口从一轮中间开始（`turn/start` 在窗口外）→ 仍出一组、不丢行，但这组无头，
        // 不假装完整。
        let headless = assemble([
            #"{"type":"tool/call","seq":120,"time":1200,"data":{"turn":12,"step":2,"callId":"c8","name":"bash","arguments":"{}"}}"#,
            #"{"type":"tool/result","seq":121,"time":1210,"data":{"turn":12,"step":2,"message":{"role":"tool","source":{"kind":"tool","callId":"c8"},"content":[{"type":"text","text":"ok"}],"isError":false,"id":"m4"}}}"#,
        ])
        XCTAssertTrue(processes(in: headless.nodes).count == 1, "A7b 窗口切半也要出一组，不丢行")
        XCTAssertTrue(processes(in: headless.nodes).first?.hasHeader == false, "A7c turn/start 在窗口外 → 无头")
        XCTAssertTrue(processes(in: headless.nodes).first?.turn == 12, "A7d 轮次号仍如实标出")

        // 一轮里「最终答案」与「中间过程」的划界 —— 折叠的范围建立在这条判定上，规则照上游
        //     `latestAnswer`：取该轮**最后一个 step** 的助手消息，须含真正的回复内容、
        //     且不含工具调用块。

        // A9a：最后一步的助手消息有文本、无工具调用 → 是最终答案，不进过程。
        let answer = assemble([
            #"{"type":"turn/start","seq":130,"time":1300,"data":{"turn":13}}"#,
            #"{"type":"step/start","seq":131,"time":1310,"data":{"turn":13,"step":1}}"#,
            #"{"type":"assistant/message","seq":132,"time":1320,"data":{"turn":13,"step":1,"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"reasoning","text":"想一想"},{"type":"text","text":"结论如下\n就是这样。"}]}}}"#,
            #"{"type":"step/end","seq":133,"time":1330,"data":{"turn":13,"step":1}}"#,
            #"{"type":"turn/end","seq":134,"time":1340,"data":{"turn":13,"reason":{"kind":"completed"}}}"#,
        ])
        XCTAssertTrue(messages(in: answer.nodes).count == 1, "A9a 出一条最终答案消息")
        XCTAssertTrue(messages(in: answer.nodes).first?.text == "结论如下\n就是这样。", "A9b 答案正文完整保留")
        XCTAssertTrue(processes(in: answer.nodes).first?.entries.contains { if case .text = $0 { return true }; return false } == false, "A9c 答案不重复出现在过程里")

        // A9d：含工具调用的消息**不是**答案 —— 哪怕它有文本。它的文本进过程。
        let toolish = assemble([
            #"{"type":"turn/start","seq":140,"time":1400,"data":{"turn":14}}"#,
            #"{"type":"step/start","seq":141,"time":1410,"data":{"turn":14,"step":1}}"#,
            #"{"type":"assistant/message","seq":142,"time":1420,"data":{"turn":14,"step":1,"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"text","text":"我去查一下"},{"type":"tool-call","id":"call_x","name":"bash","arguments":"{}"}]}}}"#,
            #"{"type":"tool/call","seq":143,"time":1430,"data":{"turn":14,"step":1,"callId":"call_x","name":"bash","arguments":"{}"}}"#,
            #"{"type":"step/end","seq":144,"time":1440,"data":{"turn":14,"step":1}}"#,
            #"{"type":"turn/end","seq":145,"time":1450,"data":{"turn":14,"reason":{"kind":"completed"}}}"#,
        ])
        XCTAssertTrue(messages(in: toolish.nodes).isEmpty, "A9d 含工具调用的消息不出答案")
        XCTAssertTrue(processes(in: toolish.nodes).first?.entries.contains { if case .text(_, let text, _) = $0 { return text == "我去查一下" }; return false } == true, "A9e 它的文本进过程")

        // A9f：该轮**最后一个 step 没有助手消息** → 本轮没有答案，
        // 不能拿前面 step 说过的话冒充最终回答。
        let noAnswer = assemble([
            #"{"type":"turn/start","seq":150,"time":1500,"data":{"turn":15}}"#,
            #"{"type":"step/start","seq":151,"time":1510,"data":{"turn":15,"step":1}}"#,
            #"{"type":"assistant/message","seq":152,"time":1520,"data":{"turn":15,"step":1,"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"text","text":"中间说过的话"}]}}}"#,
            #"{"type":"step/end","seq":153,"time":1530,"data":{"turn":15,"step":1}}"#,
            #"{"type":"step/start","seq":154,"time":1540,"data":{"turn":15,"step":2}}"#,
            #"{"type":"turn/end","seq":155,"time":1550,"data":{"turn":15,"reason":{"kind":"error"}}}"#,
        ])
        XCTAssertTrue(messages(in: noAnswer.nodes).isEmpty, "A9f 最后一步没有消息 → 本轮没有答案")
        XCTAssertTrue(processes(in: noAnswer.nodes).first?.entries.contains { if case .text(_, let text, _) = $0 { return text == "中间说过的话" }; return false } == true, "A9g 它落进过程，不丢")

        // A3 的补充：一轮里多步 —— 前一步收口只该影响那一步的调用，不能连累后一步还在跑的。
        report = assemble([
            #"{"type":"turn/start","seq":160,"time":1600,"data":{"turn":16}}"#,
            #"{"type":"step/start","seq":161,"time":1610,"data":{"turn":16,"step":1}}"#,
            #"{"type":"tool/call","seq":162,"time":1620,"data":{"turn":16,"step":1,"callId":"c9","name":"bash","arguments":"{}"}}"#,
            #"{"type":"step/end","seq":163,"time":1630,"data":{"turn":16,"step":1}}"#,
            #"{"type":"step/start","seq":164,"time":1640,"data":{"turn":16,"step":2}}"#,
            #"{"type":"tool/call","seq":165,"time":1650,"data":{"turn":16,"step":2,"callId":"c10","name":"bash","arguments":"{}"}}"#,
        ])
        rows = toolRows(in: report.nodes)
        XCTAssertTrue(rows.count == 2, "A3d 两步的调用都出")
        XCTAssertTrue(rows[0].status == .interrupted, "A3e 已收口那一步的调用 → 中断")
        XCTAssertTrue(rows[1].status == .running, "A3f 后一步还在跑 → 不被前一步连累")

        // A5：思考与工具调用交替时，显示顺序 = 事件顺序（不按类型分组）。
        let interleaved = assemble([
            #"{"type":"turn/start","seq":170,"time":1700,"data":{"turn":17}}"#,
            #"{"type":"step/start","seq":171,"time":1710,"data":{"turn":17,"step":1}}"#,
            #"{"type":"assistant/message","seq":172,"time":1720,"data":{"turn":17,"step":1,"message":{"content":[{"type":"reasoning","text":"先想想"}]}}}"#,
            #"{"type":"tool/call","seq":173,"time":1730,"data":{"turn":17,"step":1,"callId":"d1","name":"bash","arguments":"{}"}}"#,
            #"{"type":"tool/result","seq":174,"time":1740,"data":{"turn":17,"step":1,"message":{"source":{"kind":"tool","callId":"d1"},"content":[{"type":"text","text":"ok"}],"isError":false}}}"#,
            #"{"type":"assistant/message","seq":175,"time":1750,"data":{"turn":17,"step":1,"message":{"content":[{"type":"reasoning","text":"再想想"}]}}}"#,
            #"{"type":"tool/call","seq":176,"time":1760,"data":{"turn":17,"step":1,"callId":"d2","name":"glob","arguments":"{}"}}"#,
        ])
        let order = (processes(in: interleaved.nodes).first?.entries ?? []).map { entry -> String in
            switch entry {
            case .thinking(_, let text, _): return "思考:\(text)"
            case .tool(let row): return "工具:\(row.callId)"
            case .text(_, let text, _): return "文本:\(text)"
            }
        }
        XCTAssertTrue(order == ["思考:先想想", "工具:d1", "思考:再想想", "工具:d2"], "A5 交替顺序 = 事件顺序")

        // A6：折叠头上的一句话。计数为 0 的不写出来，只有思考时写兜底文案。
        XCTAssertTrue(processes(in: interleaved.nodes).first?.summary == "2 次工具调用", "A6a 只有工具调用 → 只写工具数")

        let mixed = assemble([
            #"{"type":"turn/start","seq":180,"time":1800,"data":{"turn":18}}"#,
            #"{"type":"step/start","seq":181,"time":1810,"data":{"turn":18,"step":1}}"#,
            #"{"type":"tool/call","seq":182,"time":1820,"data":{"turn":18,"step":1,"callId":"e1","name":"bash","arguments":"{}"}}"#,
            #"{"type":"assistant/message","seq":183,"time":1830,"data":{"turn":18,"step":1,"message":{"content":[{"type":"text","text":"我看一下"},{"type":"tool-call","id":"e2","name":"glob","arguments":"{}"}]}}}"#,
            #"{"type":"tool/call","seq":184,"time":1840,"data":{"turn":18,"step":1,"callId":"e2","name":"glob","arguments":"{}"}}"#,
        ])
        XCTAssertTrue(processes(in: mixed.nodes).first?.summary == "2 次工具调用 · 1 条消息", "A6b 工具与中间文本并列")

        let thinking = assemble([
            #"{"type":"turn/start","seq":190,"time":1900,"data":{"turn":19}}"#,
            #"{"type":"step/start","seq":191,"time":1910,"data":{"turn":19,"step":1}}"#,
            #"{"type":"assistant/message","seq":192,"time":1920,"data":{"turn":19,"step":1,"message":{"content":[{"type":"reasoning","text":"只是想了一下"}]}}}"#,
            #"{"type":"step/end","seq":193,"time":1930,"data":{"turn":19,"step":1}}"#,
        ])
        XCTAssertTrue(processes(in: thinking.nodes).first?.summary == "已思考", "A6c 只有思考 → 兜底文案，不写 0 次工具调用")

        let empty = assemble([
            #"{"type":"turn/start","seq":200,"time":2000,"data":{"turn":20}}"#,
            #"{"type":"step/start","seq":201,"time":2010,"data":{"turn":20,"step":1}}"#,
            #"{"type":"step/end","seq":202,"time":2020,"data":{"turn":20,"step":1}}"#,
        ])
        XCTAssertTrue(processes(in: empty.nodes).isEmpty, "A6d 三者皆空 → 不画这一行")

        // A7e：用户消息夹在 `turn/start` 与助手首个输出之间
        // （真机日志里 13 个 `turn/start` 全如此）——
        //      那句要排到过程前面，但本轮远没结束，「有头」的身份不能被一起收掉。
        let interleavedInput = assemble([
            #"{"type":"turn/start","seq":210,"time":2100,"data":{"turn":21}}"#,
            #"{"type":"step/start","seq":211,"time":2110,"data":{"turn":21,"step":1}}"#,
            #"{"type":"user/message","seq":212,"time":2120,"data":{"role":"user","source":{"kind":"user"},"content":[{"type":"text","text":"帮我看看"}]}}"#,
            #"{"type":"assistant/message","seq":213,"time":2130,"data":{"turn":21,"step":1,"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"reasoning","text":"嗯"},{"type":"text","text":"看完了"}]}}}"#,
            #"{"type":"turn/end","seq":214,"time":2140,"data":{"turn":21,"reason":{"kind":"completed"}}}"#,
        ])
        XCTAssertTrue(processes(in: interleavedInput.nodes).first?.hasHeader == true, "A7e 输入夹在中间也不该把这一组判成无头")
        XCTAssertTrue(messages(in: interleavedInput.nodes).first?.text == "帮我看看", "A7f 那句用户消息排在过程之前")

        sliceChecks()
    }

    // MARK: - 切片：窗口会变（打开 / 往回翻 / 冷启动重取）

    /// 组装一段**已经是 `SessionEvent`** 的事件（切片判据从镜像取事件，不走 JSON 串）。
    private func assemble(_ events: [SessionEvent]) -> (nodes: [TranscriptNode], unknown: [String]) {
        var unknown: [String] = []
        var assembler = TranscriptAssembler(onUnknownEventType: { unknown.append($0) })
        return (assembler.assemble(events), unknown)
    }

    /// 一页：末尾接在 `endSeq` 上 —— 服务端的响应形状（`pageStart` 本页首条、
    /// `asOfSeq` 本页末尾之后）。
    private func page(_ events: [SessionEvent], from startSeq: Int, to endSeq: Int,
                      hasOlder: Bool) -> SessionPage {
        let slice = events.filter { $0.seq >= startSeq && $0.seq < endSeq }
        return SessionPage(
            pageStart: slice.first?.seq ?? 0,
            asOfSeq: endSeq,
            hasOlder: hasOlder,
            events: slice
        )
    }

    private func sliceResult(seq: Int, callId: String, turn: Int, step: Int, text: String) -> String {
        #"{"type":"tool/result","seq":\#(seq),"time":\#(seq * 10),"data":{"turn":\#(turn),"step":\#(step),"message":{"role":"tool","source":{"kind":"tool","callId":"\#(callId)"},"toolCallId":"\#(callId)","content":[{"type":"text","text":"\#(text)"}],"isError":false,"id":"m\#(seq)"}}}"#
    }

    private func sliceAssistant(seq: Int, turn: Int, step: Int, text: String) -> String {
        #"{"type":"assistant/message","seq":\#(seq),"time":\#(seq * 10),"data":{"turn":\#(turn),"step":\#(step),"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"text","text":"\#(text)"}]}}}"#
    }

    /// 两页事件流：第 7 轮完整，**第 8 轮被切口切成两页**（切口落在过程行中间）。形状照真机会话：
    /// 用户消息排在轮次之前，第 8 轮中间还有一次助手文本（不是答案），答案是第二步那条。
    private var sliceStream: [SessionEvent] {
        [
            #"{"type":"user/message","seq":300,"time":3000,"data":{"role":"user","source":{"kind":"user"},"content":[{"type":"text","text":"第一问"}]}}"#,
            #"{"type":"turn/start","seq":301,"time":3010,"data":{"turn":7}}"#,
            #"{"type":"step/start","seq":302,"time":3020,"data":{"turn":7,"step":1}}"#,
            #"{"type":"tool/call","seq":303,"time":3030,"data":{"turn":7,"step":1,"callId":"c7","name":"bash","arguments":"{\"command\": \"ls\"}"}}"#,
            sliceResult(seq: 304, callId: "c7", turn: 7, step: 1, text: "文件列表"),
            sliceAssistant(seq: 305, turn: 7, step: 1, text: "第一答"),
            #"{"type":"step/end","seq":306,"time":3060,"data":{"turn":7,"step":1}}"#,
            #"{"type":"turn/end","seq":307,"time":3070,"data":{"turn":7,"reason":{"kind":"completed"}}}"#,
            #"{"type":"user/message","seq":308,"time":3080,"data":{"role":"user","source":{"kind":"user"},"content":[{"type":"text","text":"第二问"}]}}"#,
            #"{"type":"turn/start","seq":309,"time":3090,"data":{"turn":8}}"#,
            #"{"type":"step/start","seq":310,"time":3100,"data":{"turn":8,"step":1}}"#,
            #"{"type":"tool/call","seq":311,"time":3110,"data":{"turn":8,"step":1,"callId":"c8","name":"bash","arguments":"{\"command\": \"pwd\"}"}}"#,
            sliceResult(seq: 312, callId: "c8", turn: 8, step: 1, text: "/tmp"),
            sliceAssistant(seq: 313, turn: 8, step: 1, text: "去看一眼"),
            #"{"type":"step/start","seq":314,"time":3140,"data":{"turn":8,"step":2}}"#,
            #"{"type":"tool/call","seq":315,"time":3150,"data":{"turn":8,"step":2,"callId":"c9","name":"bash","arguments":"{\"command\": \"ls -la\"}"}}"#,
            sliceResult(seq: 316, callId: "c9", turn: 8, step: 2, text: "ok"),
            sliceAssistant(seq: 317, turn: 8, step: 2, text: "第二答"),
            #"{"type":"step/end","seq":318,"time":3180,"data":{"turn":8,"step":2}}"#,
            #"{"type":"turn/end","seq":319,"time":3190,"data":{"turn":8,"reason":{"kind":"completed"}}}"#,
        ].map(event)
    }

    /// 判据 S1–S5：**同一批事件换一个窗口再看一遍，屏上会变什么。** A1–A9 验定死的事件，
    /// 这里验窗口会动：
    /// 打开 = 最新一页、往回翻 = 前插、冷启动 = 重取。三者里只有前插改已渲染内容，
    /// 且只落在**一处** ——
    /// 窗口头部那一组（其余各组开头都在窗口里，前插内容排在它们之前）；
    /// 结论由真机日志实跑得到（会话 a
    /// 取 30–200 各种窗口尺寸逐个比对），这里钉住。
    private func sliceChecks() {
        let stream = sliceStream

        // S1：打开最新的那一页 —— 切口在一轮中间。
        var openMirror = SessionMirror()
        let openVerdict = openMirror.open(with: page(stream, from: 313, to: 9_999, hasOlder: true))
        let opened = assemble(openMirror.events)
        XCTAssertTrue(openVerdict == .merged(added: 7), "S1a 打开窗口：镜像收下这一页")
        XCTAssertTrue(processes(in: opened.nodes).count == 1, "S1b 切口在一轮中间 → 仍出一组过程")
        XCTAssertTrue(processes(in: opened.nodes).first?.hasHeader == false, "S1c 这一轮的开头不在窗口里 → 无头，不假装完整")
        XCTAssertTrue(toolRows(in: opened.nodes).count == 1, "S1d 头组里的工具行不丢")
        XCTAssertTrue(messages(in: opened.nodes).map(\.seq) == [317], "S1e 答案仍单独成节点")

        // S2：往回翻一页 —— 第 8 轮的开头在这一页里。
        var pagedMirror = SessionMirror()
        _ = pagedMirror.open(with: page(stream, from: 313, to: 9_999, hasOlder: true))
        let prependVerdict = pagedMirror.prepend(page(stream, from: 308, to: 313, hasOlder: true))
        let paged = assemble(pagedMirror.events)
        XCTAssertTrue(prependVerdict == .merged(added: 5), "S2a 前插：紧邻的一段接得上")
        XCTAssertTrue(toolRows(in: paged.nodes).count == 2, "S2b 前插只往头组里加行，不吞掉原有的")
        XCTAssertTrue(messages(in: paged.nodes).map(\.seq) == [308, 317], "S2c 前插后消息顺序照旧")

        // S2 的要害：**前插不改动屏上其余各行。**
        let openedTail = Array(opened.nodes.dropFirst())
        XCTAssertTrue(Array(paged.nodes.suffix(openedTail.count)) == openedTail, "S2d 除头组外逐条相同（值相等）")
        let openedIds = Set(opened.nodes.dropFirst().map(\.id))
        XCTAssertTrue(openedIds.subtracting(Set(paged.nodes.map(\.id))).isEmpty, "S2e 除头组外的身份全部保留（不重挂载）")
        XCTAssertTrue(processes(in: paged.nodes).first?.hasHeader == true, "S2f 头组由无头变有头 —— 它的形态本来就变了")

        // S3：过程行的身份取「种类 + 事件 seq」而非组内偏移 —— 前插插行时偏移整体挪位、seq 不挪；
        // 否则已展开的工具行每次往回翻会收回去。
        let openedEntries = processes(in: opened.nodes).first?.entries.map(\.id) ?? []
        let pagedEntries = processes(in: paged.nodes).first?.entries.map(\.id) ?? []
        XCTAssertTrue(openedEntries == ["text-313", "tool-315"], "S3a 过程行身份 = 种类 + 事件 seq")
        XCTAssertTrue(pagedEntries.prefix(3) == ["tool-311", "text-313", "tool-315"], "S3b 前插把新行插在前面，不打乱既有行的身份")
        XCTAssertTrue(pagedEntries.suffix(openedEntries.count) == openedEntries, "S3c 头组里原有的行身份不变")

        // S3 的另一面：身份在组内**唯一** —— 同一条助手消息产出的「思考」与「文本」两行 seq 相同，
        // 靠种类前缀才区分；不区分就是两个同 id 行，
        // SwiftUI 的 diff 会错乱（少/多/串位都从这里来）。
        let twin = assemble([
            #"{"type":"turn/start","seq":400,"time":4000,"data":{"turn":20}}"#,
            #"{"type":"step/start","seq":401,"time":4010,"data":{"turn":20,"step":1}}"#,
            #"{"type":"assistant/message","seq":402,"time":4020,"data":{"turn":20,"step":1,"message":{"content":[{"type":"reasoning","text":"想一想"},{"type":"text","text":"去看一眼"}]}}}"#,
            #"{"type":"step/end","seq":403,"time":4030,"data":{"turn":20,"step":1}}"#,
            #"{"type":"step/start","seq":404,"time":4040,"data":{"turn":20,"step":2}}"#,
            #"{"type":"tool/call","seq":405,"time":4050,"data":{"turn":20,"step":2,"callId":"f2","name":"bash","arguments":"{}"}}"#,
        ])
        let twinEntries = processes(in: twin.nodes).first?.entries.map(\.id) ?? []
        XCTAssertTrue(twinEntries == ["thinking-402", "text-402", "tool-405"], "S3d 同一条消息的两行 seq 相同、靠种类区分")
        XCTAssertTrue(Set(twinEntries).count == twinEntries.count, "S3e 组内身份唯一")

        // S4：冷启动 —— 重取同一个窗口（新镜像、同一批事件）。
        var coldMirror = SessionMirror()
        _ = coldMirror.open(with: page(stream, from: 313, to: 9_999, hasOlder: true))
        let cold = assemble(coldMirror.events)
        XCTAssertTrue(cold.nodes == opened.nodes, "S4a 冷启动重取同一窗口 → 组装结果逐条相同（不因重取而漂）")
        XCTAssertTrue(toolRows(in: cold.nodes).count == 1, "S4b 冷启动后工具行重新出现（静态形态）")

        // S5：边界切在 `tool/call` 与它的结果之间 ——
        // 真机日志里这类窗口确实存在（会话 a 的窗口 44/58/72/93/184 都挑出「只有结果」的行）。
        var cutMirror = SessionMirror()
        _ = cutMirror.open(with: page(stream, from: 316, to: 9_999, hasOlder: true))
        let cut = assemble(cutMirror.events)
        XCTAssertTrue(toolRows(in: cut.nodes).count == 1, "S5a 调用在窗口外 → 仍出一行，不丢")
        XCTAssertTrue(toolRows(in: cut.nodes).first?.name == nil, "S5b 不知道工具名就不编一个")
        XCTAssertTrue(toolRows(in: cut.nodes).first?.argumentsRaw == nil, "S5c 也不假装有参数")
        XCTAssertTrue(toolRows(in: cut.nodes).first?.resultText == "ok", "S5d 结果本身照常显示")

        // S5 的另一半：往回翻把那条调用带进来 → 同一行从「不知道」变「知道」。
        var healedMirror = SessionMirror()
        _ = healedMirror.open(with: page(stream, from: 316, to: 9_999, hasOlder: true))
        _ = healedMirror.prepend(page(stream, from: 315, to: 316, hasOlder: true))
        let healed = toolRows(in: assemble(healedMirror.events).nodes)
        XCTAssertTrue(healed.first?.name == "bash", "S5e 前插带回那条调用 → 同一行补上工具名")
        XCTAssertTrue(healed.first?.argumentsRaw?.isEmpty == false, "S5f 参数也补上了")
    }

    // MARK: - 命令（O5）：结果从流里来，按 commandId 配对

    /// 把节点里的命令行摊平出来。
    private func commandRows(in nodes: [TranscriptNode]) -> [CommandRun] {
        nodes.compactMap { node -> CommandRun? in
            guard case .command(let run) = node else { return nil }
            return run
        }
    }

    /// 只有 `command/run` 时那一行是「执行中」；`command/done` 到达后**同一行**换成结局。
    /// 配对的键是 `commandId` —— 按 seq 猜会在这两条事件不连续时配错。
    func testCommandRunAndDonePairUpOnTheSameRow() {
        let run = #"{"type":"command/run","seq":10,"time":1,"data":{"commandId":"cmd-7","name":"permission","args":" read-only","source":{"kind":"user"}}}"#
        let done = #"{"type":"command/done","seq":12,"time":2,"data":{"commandId":"cmd-7","kind":"success","text":"preset read-only"}}"#

        let started = commandRows(in: assemble([run]).nodes)
        XCTAssertEqual(started.count, 1, "run 一到就出一行")
        XCTAssertEqual(started.first?.invocation, "/permission  read-only", "名字 + 原样参数")
        XCTAssertNil(started.first?.outcome, "还没结束：执行中")

        let settled = commandRows(in: assemble([run, done]).nodes)
        XCTAssertEqual(settled.count, 1, "done 不新增行 —— 它把同一行换掉")
        XCTAssertEqual(settled.first?.outcome, .success("preset read-only"), "结局是宿主给的原文")
        XCTAssertEqual(settled.first?.commandId, "cmd-7")
    }

    /// 失败的结局也要看得见，且不是 success。
    func testCommandFailureIsVisible() {
        let run = #"{"type":"command/run","seq":10,"time":1,"data":{"commandId":"cmd-8","name":"goal"}}"#
        let done = #"{"type":"command/done","seq":11,"time":2,"data":{"commandId":"cmd-8","kind":"error","text":"boom"}}"#
        let rows = commandRows(in: assemble([run, done]).nodes)
        XCTAssertEqual(rows.first?.outcome, .failure("boom"), "失败原样带宿主那句")
    }

    /// `command/run` 在窗口外（往回翻的边界）→ 仍出一行，但不编造命令名。
    func testCommandDoneWithoutItsRunDoesNotInventAName() {
        let done = #"{"type":"command/done","seq":316,"time":2,"data":{"commandId":"cmd-9","kind":"success","text":"ok"}}"#
        let rows = commandRows(in: assemble([done]).nodes)
        XCTAssertEqual(rows.count, 1, "结果本身照常显示，不丢")
        XCTAssertEqual(rows.first?.name, "", "不知道按了什么就不写名字")
        XCTAssertEqual(rows.first?.outcome, .success("ok"))
    }

    /// 两条命令交错到达也各归各行 —— **先发的先结束**。
    ///
    /// 这组顺序是刻意的：把配对改成「配给最近一条还没有结局的命令」时，`doneA` 会贴到
    /// `cmd-b` 上，结局互换，断言变红。
    ///
    /// 下面还有一条「后发的先结束」——**两条合起来**才同时挡住 FIFO 与 LIFO 两种猜法：
    /// 只留一种顺序时，其中一种猜法会碰巧全对（单条绿灯不代表配对键对）。
    func testTwoInterleavedCommandsDoNotSwapOutcomes() {
        let runA = #"{"type":"command/run","seq":10,"time":1,"data":{"commandId":"cmd-a","name":"compact"}}"#
        let runB = #"{"type":"command/run","seq":11,"time":1,"data":{"commandId":"cmd-b","name":"export"}}"#
        let doneA = #"{"type":"command/done","seq":12,"time":2,"data":{"commandId":"cmd-a","kind":"success","text":"done"}}"#
        let doneB = #"{"type":"command/done","seq":13,"time":2,"data":{"commandId":"cmd-b","kind":"error","text":"no such dir"}}"#
        let rows = commandRows(in: assemble([runA, runB, doneA, doneB]).nodes)
        XCTAssertEqual(rows.first(where: { $0.commandId == "cmd-a" })?.outcome, .success("done"))
        XCTAssertEqual(rows.first(where: { $0.commandId == "cmd-b" })?.outcome, .failure("no such dir"))
    }

    /// 同一个交错场景、**先发的后结束**。挡住「配给第一条还没有结局的命令」那种猜法。
    func testTwoInterleavedCommandsFinishingOutOfOrder() {
        let runA = #"{"type":"command/run","seq":10,"time":1,"data":{"commandId":"cmd-a","name":"compact"}}"#
        let runB = #"{"type":"command/run","seq":11,"time":1,"data":{"commandId":"cmd-b","name":"export"}}"#
        let doneB = #"{"type":"command/done","seq":12,"time":2,"data":{"commandId":"cmd-b","kind":"error","text":"no such dir"}}"#
        let doneA = #"{"type":"command/done","seq":13,"time":2,"data":{"commandId":"cmd-a","kind":"success","text":"done"}}"#
        let rows = commandRows(in: assemble([runA, runB, doneB, doneA]).nodes)
        XCTAssertEqual(rows.first(where: { $0.commandId == "cmd-a" })?.outcome, .success("done"))
        XCTAssertEqual(rows.first(where: { $0.commandId == "cmd-b" })?.outcome, .failure("no such dir"))
    }

    /// 命令事件是**已消费**的类型：不该被当成「不认识的事件类型」上报。
    func testCommandEventsAreNotReportedAsUnknown() {
        let run = #"{"type":"command/run","seq":10,"time":1,"data":{"commandId":"cmd-7","name":"compact"}}"#
        let done = #"{"type":"command/done","seq":11,"time":2,"data":{"commandId":"cmd-7","kind":"success"}}"#
        let result = assemble([run, done])
        XCTAssertEqual(result.unknown, [], "命令事件有处理器，不该进未知类型的上报")
    }

    // MARK: - 上游这份版本认识的事件类型

    /// `packages/core/session/src/known-event-types.ts` 的 `KNOWN_SESSION_EVENT_TYPES` 抄录
    /// （2026-11-03，62 条）。**升级 harness 时重抄一遍**，然后跑下面那条判据。
    ///
    /// 它是「上游到底有哪些类型」的唯一记录：漏抄不会假绿 —— 判据的活性锚是同一次跑里
    /// 一个真的新类型必须被报出来；但**多抄一个上游已经没有的类型**不会被发现，因为那种
    /// 情况下它照样被旁路清单盖住。抄的时候照原样抄，别顺手删。
    private static let upstreamEventTypes = [
        "agent-preset/selected", "agent/inbox/spliced", "approval/asked", "approval/decided",
        "approval/policy", "assistant/attempt", "assistant/message", "command/done",
        "command/run", "compaction/end", "compaction/prune", "compaction/start",
        "compaction/summary", "deliverables/presented", "developer/message",
        "feedback/message-delete", "feedback/message-put", "feedback/record", "goal/change",
        "hook/invoked", "hook/result", "image/offload", "job/registered", "job/settled",
        "llm/retry", "llm/retry-started", "model/selection", "permission/preset", "plan/mode",
        "request/context", "request/header", "sandbox/mode", "schedule/change",
        "session-log-deepseek/delivery-accepted", "session/end-seed", "session/title",
        "session/title-llm-request", "step/end", "step/start", "subagent/catalog",
        "subagent/descriptor", "subagent/model-selection-policy", "system/message",
        "team/member", "team/message/delivered", "team/message/queued", "team/task",
        "todo/write", "tool-workflow/agent-end", "tool-workflow/agent-start",
        "tool-workflow/run-end", "tool-workflow/run-start", "tool/call", "tool/ptc-dispatch",
        "tool/ptc-dispatch-start", "tool/result", "turn/end", "turn/start", "user/message",
        "web/deepseek-search-llm-request", "working-directory/change", "workspace/changes"
    ]

    /// 上游这份版本里的每一个类型，都不该被当成「上游加了新东西」报出来。
    ///
    /// 这一条守的是**降噪清单的保质期**。清单是前缀式的，上游每加一个命名空间
    /// （`job/`、`team/`、`tool-workflow/`…）就会有一批已知类型落进 `default` 分支，
    /// 于是每次打开会话都在 Xcode 里刷一片「不认识的事件类型」—— 而它们既不改变显示，
    /// 也不是新东西。实测栽过一次：`deliverables/presented` 被写成 `deliverable/`（少个 s），
    /// 于是每打开一次会话都报一次。
    ///
    /// 判据打的是**行为**而不是那个清单本身：`isKnownBypass` 是 fileprivate，
    /// 而真正要守的也正是「这条事件进来之后有没有被上报」。
    func testEveryUpstreamEventTypeIsAccountedFor() {
        XCTAssertGreaterThanOrEqual(Self.upstreamEventTypes.count, 50, "清单太短 —— 抄漏了")
        XCTAssertEqual(Set(Self.upstreamEventTypes).count, Self.upstreamEventTypes.count,
                       "清单里有重复：抄的时候按原样抄，不要手工去重")

        let batch = Self.upstreamEventTypes.map {
            #"{"type":"\#($0)","seq":1,"time":1,"data":{}}"#
        }
        let reported = assemble(batch).unknown
        XCTAssertEqual(reported, [],
                       "这些是上游这份版本自己的类型，不该报成「上游加了新东西」：\(reported)")

        // 活性锚：同一次装配里，一个真的不在清单里的类型必须被报出来 ——
        // 否则上面那条对「永远不会上报」的实现也成立。
        let control = assemble([#"{"type":"future/not-in-this-build","seq":1,"time":1,"data":{}}"#])
        XCTAssertEqual(control.unknown, ["future/not-in-this-build"],
                       "上报这条路断了 —— 上面那条此刻在测一个不会发生的分支")
    }
}

/**
 * 会话详情组装器的测试（A1–A4、A8）。
 *
 * 与 `SessionMirrorTests` / `UsageStateTests` 同一手法：组装器是纯状态机，
 * 不 import SwiftUI / UIKit、不碰网络、不碰磁盘 —— 这里直接喂事件数组、
 * 断言显示节点。所以「配对、状态、退化」这些最容易错的判断都能离线验。
 *
 * 判据与出处：docs/dev/plans/M6-presentation-layer.md §五（A1–A4、A8）。
 * 配对与状态判定照**运行时产物**（`@deepseek-ai/dsh-client-ui-chat`）：
 * - 配对 id = `tool/call.data.callId` ↔ `tool/result.data.message.source.callId`
 * - 失败标记 = `tool/result.data.message.isError`（**不是** `content[0].isError` ——
 *   clone 的仓库版本落后于运行时，实测日志里前者有值、后者从不出现）
 * - 中断 = 所在 step / turn 已关闭，而这条 call 一直没有结果
 */
import Foundation

@main
struct TranscriptAssemblerTests {

    private static var passed = 0
    private static var failed = 0

    private static func expect(_ ok: Bool, _ label: String) {
        if ok {
            passed += 1
            print("ok   \(label)")
        } else {
            failed += 1
            print("FAIL \(label)")
        }
    }

    /// 从线的形状直接造一条事件 —— 事件体原样透传，所以测试里也照原样写。
    private static func event(_ json: String) -> SessionEvent {
        do {
            return try JSONDecoder().decode(SessionEvent.self, from: Data(json.utf8))
        } catch {
            fatalError("测试事件解不出来：\(error)\n\(json)")
        }
    }

    /// 组装一段事件，同时收下「上报的不认识类型」。
    private static func assemble(_ json: [String]) -> (nodes: [TranscriptNode], unknown: [String]) {
        var unknown: [String] = []
        var assembler = TranscriptAssembler(onUnknownEventType: { unknown.append($0) })
        return (assembler.assemble(json.map(event)), unknown)
    }

    /// 把节点里的工具行摊平出来 —— 断言只关心它们，不关心折叠结构。
    private static func toolRows(in nodes: [TranscriptNode]) -> [ToolRow] {
        nodes.flatMap { node -> [ToolRow] in
            guard case .process(let process) = node else { return [] }
            return process.entries.compactMap { entry in
                if case .tool(let row) = entry { return row }
                return nil
            }
        }
    }

    /// 把节点里的过程摊平出来。
    private static func processes(in nodes: [TranscriptNode]) -> [NodeProcess] {
        nodes.compactMap { node in
            if case .process(let process) = node { return process }
            return nil
        }
    }

    /// 把节点里的消息摊平出来。
    private static func messages(in nodes: [TranscriptNode]) -> [DisplayMessage] {
        nodes.compactMap { node in
            if case .message(let message) = node { return message }
            return nil
        }
    }

    private static let call = #"{"type":"tool/call","seq":11,"time":110,"data":{"turn":1,"step":1,"callId":"c1","name":"bash","arguments":"{\"command\": \"pwd && ls -la\", \"description\": \"List workspace contents\"}"}}"#

    private static func result(seq: Int, isError: Bool = false, text: String = "total 8") -> String {
        #"{"type":"tool/result","seq":\#(seq),"time":\#(seq * 10),"data":{"turn":1,"step":1,"message":{"role":"tool","source":{"kind":"tool","callId":"c1"},"toolCallId":"c1","content":[{"type":"text","text":"\#(text)"}],"isError":\#(isError),"id":"m1"}}}"#
    }

    static func main() {
        // A1：一组 call + result（同一 callId、isError 假）→ 一行「成功」，
        //     摘要取参数里的 description（上游候选键里它排在 command 之前）。
        var report = assemble([
            #"{"type":"turn/start","seq":10,"time":100,"data":{"turn":1}}"#,
            call,
            result(seq: 12),
            #"{"type":"turn/end","seq":13,"time":130,"data":{"turn":1,"reason":{"kind":"completed"}}}"#,
        ])
        var rows = toolRows(in: report.nodes)
        expect(rows.count == 1, "A1a 一对 call/result 出一行")
        expect(rows.first?.status == .succeeded, "A1b isError 假 → 成功")
        expect(rows.first?.name == "bash", "A1c 工具名取自 call")
        expect(rows.first?.summary == "List workspace contents", "A1d 摘要取候选键里靠前的 description")
        expect(rows.first?.argumentsRaw?.isEmpty == false, "A1e 原始参数留给展开看")
        expect(rows.first?.resultText == "total 8", "A1f 结果正文留给展开看")
        expect(rows.first?.errorCode == nil, "A1g 成功不报错")

        // A1 的兜底：候选键都没命中时回落到工具名，不会显示成空。
        report = assemble([
            #"{"type":"tool/call","seq":20,"time":200,"data":{"turn":2,"step":1,"callId":"c2","name":"glob","arguments":"{\"other\": 1}"}}"#,
            #"{"type":"tool/result","seq":21,"time":210,"data":{"turn":2,"step":1,"message":{"role":"tool","source":{"kind":"tool","callId":"c2"},"content":[{"type":"text","text":"ok"}],"isError":false,"id":"m2"}}}"#,
        ])
        rows = toolRows(in: report.nodes)
        expect(rows.first?.summary == "glob", "A1h 参数里没有可读键时回落工具名")

        // A2a：只有 call（没有 result）→ 「运行中」，不假装有结果。
        report = assemble([call])
        rows = toolRows(in: report.nodes)
        expect(rows.first?.status == .running, "A2a 只有 call → 运行中")
        expect(rows.first?.resultText == nil, "A2b 没有结果就不给结果")

        // A2b：只有 result（call 在窗口外）→ 出工具行但不假装有参数。
        report = assemble([result(seq: 30)])
        rows = toolRows(in: report.nodes)
        expect(rows.count == 1, "A2c 只有 result 也出一行（不丢）")
        expect(rows.first?.status == .succeeded, "A2d 只有 result 时状态仍由 isError 定")
        expect(rows.first?.name == nil, "A2e 不知道工具名就不编一个")
        expect(rows.first?.argumentsRaw == nil, "A2f call 不在窗口里就不假装有参数")

        // A3：轮次关闭而 call 没有结果 → 「中断」，不是永远「运行中」。
        report = assemble([
            #"{"type":"turn/start","seq":40,"time":400,"data":{"turn":3}}"#,
            #"{"type":"tool/call","seq":41,"time":410,"data":{"turn":3,"step":1,"callId":"c3","name":"bash","arguments":"{}"}}"#,
            #"{"type":"step/end","seq":42,"time":420,"data":{"turn":3,"step":1}}"#,
        ])
        rows = toolRows(in: report.nodes)
        expect(rows.first?.status == .interrupted, "A3a step 关闭而 call 无结果 → 中断")

        report = assemble([
            #"{"type":"turn/start","seq":50,"time":500,"data":{"turn":4}}"#,
            #"{"type":"tool/call","seq":51,"time":510,"data":{"turn":4,"step":1,"callId":"c4","name":"bash","arguments":"{}"}}"#,
            #"{"type":"turn/end","seq":52,"time":520,"data":{"turn":4,"reason":{"kind":"completed"}}}"#,
        ])
        rows = toolRows(in: report.nodes)
        expect(rows.first?.status == .interrupted, "A3b turn 关闭而 call 无结果 → 中断")

        // A3 的反面：轮次没关就还是「运行中」—— 中断不能提前发生。
        report = assemble([
            #"{"type":"turn/start","seq":60,"time":600,"data":{"turn":5}}"#,
            #"{"type":"tool/call","seq":61,"time":610,"data":{"turn":5,"step":1,"callId":"c5","name":"bash","arguments":"{}"}}"#,
        ])
        rows = toolRows(in: report.nodes)
        expect(rows.first?.status == .running, "A3c 轮次未关闭时仍是运行中")

        // A4：isError 真 → 「失败」，与 A1 的成功同一判定来源。
        report = assemble([
            call,
            #"{"type":"tool/result","seq":71,"time":710,"data":{"turn":1,"step":1,"message":{"role":"tool","source":{"kind":"tool","callId":"c1"},"content":[{"type":"text","text":"timeout"}],"isError":true,"id":"m3"},"error":{"name":"ToolTimeoutError","code":"TOOL_TIMEOUT"}}}"#,
        ])
        rows = toolRows(in: report.nodes)
        expect(rows.first?.status == .failed, "A4a isError 真 → 失败")
        expect(rows.first?.errorCode == "TOOL_TIMEOUT", "A4b 上游给的错误码照原样带上")
        expect(rows.first?.resultText == "timeout", "A4c 失败也有正文")

        // A8：一条不认识的 type 夹在已知事件之间 —— 组装结果与「没有它」逐条相同。
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
        expect(withIt.nodes == withoutIt.nodes, "A8a 不认识的类型不改变组装结果，也不崩")
        expect(withoutIt.unknown.isEmpty, "A8b 没有新类型时不上报")
        expect(withIt.unknown == ["future/streaming-thing"], "A8c 上报一次该类型")

        // A8 的补充：同一类型再来不重复上报（每次打开会话都会重放整段窗口）。
        let repeats = assemble([
            #"{"type":"future/streaming-thing","seq":90,"time":900,"data":{}}"#,
            #"{"type":"future/streaming-thing","seq":91,"time":910,"data":{}}"#,
            #"{"type":"future/other","seq":92,"time":920,"data":{}}"#,
        ])
        expect(repeats.unknown == ["future/streaming-thing", "future/other"], "A8d 按类型去重")

        // A8 的另一面：已知但归别的链路管的事件不该被当成「上游加了新东西」。
        let bypass = assemble([
            #"{"type":"approval/asked","seq":95,"time":950,"data":{"id":"a1","toolName":"bash"}}"#,
            #"{"type":"request/context","seq":96,"time":960,"data":{}}"#,
            #"{"type":"web/deepseek-search-llm-request","seq":97,"time":970,"data":{}}"#,
            #"{"type":"agent/inbox/spliced","seq":98,"time":980,"data":{}}"#,
        ])
        expect(bypass.unknown.isEmpty, "A8e 已知旁路类型不上报")

        // 用户消息仍然照常出消息节点（组装器不吞掉既有能力）。
        let user = assemble([
            #"{"type":"user/message","seq":100,"time":1000,"data":{"role":"user","source":{"kind":"user"},"content":[{"type":"text","text":"这里面有什么内容"}]}}"#,
        ])
        expect(messages(in: user.nodes).first?.text == "这里面有什么内容", "用户消息照常成节点")

        // A7a：`turn/start` 在窗口里 → 这一组有头（可以画折叠头）。
        let headed = assemble([
            #"{"type":"turn/start","seq":110,"time":1100,"data":{"turn":11}}"#,
            #"{"type":"tool/call","seq":111,"time":1110,"data":{"turn":11,"step":1,"callId":"c7","name":"bash","arguments":"{}"}}"#,
            #"{"type":"turn/end","seq":112,"time":1120,"data":{"turn":11,"reason":{"kind":"completed"}}}"#,
        ])
        expect(processes(in: headed.nodes).first?.hasHeader == true, "A7a 有 turn/start → 这一组有头")

        // A7b：窗口从一轮中间开始（`turn/start` 在窗口外）→ 仍出一组、不丢行，
        //      但这一组是「无头」的：它缺了开头，不该假装完整。
        let headless = assemble([
            #"{"type":"tool/call","seq":120,"time":1200,"data":{"turn":12,"step":2,"callId":"c8","name":"bash","arguments":"{}"}}"#,
            #"{"type":"tool/result","seq":121,"time":1210,"data":{"turn":12,"step":2,"message":{"role":"tool","source":{"kind":"tool","callId":"c8"},"content":[{"type":"text","text":"ok"}],"isError":false,"id":"m4"}}}"#,
        ])
        expect(processes(in: headless.nodes).count == 1, "A7b 窗口切半也要出一组，不丢行")
        expect(processes(in: headless.nodes).first?.hasHeader == false, "A7c turn/start 在窗口外 → 无头")
        expect(processes(in: headless.nodes).first?.turn == 12, "A7d 轮次号仍如实标出")

        // A9：一轮里「最终答案」与「中间过程」的划界 —— 决定 10 的折叠范围整个
        //     建立在它之上（过程折叠进去、答案留在原位），所以它自己得有判据。
        //     规则照上游 `latestAnswer`：取该轮**最后一个 step** 的助手消息，
        //     它必须含真正的回复内容、且不含工具调用块。

        // A9a：最后一步的助手消息有文本、无工具调用 → 是最终答案，不进过程。
        let answer = assemble([
            #"{"type":"turn/start","seq":130,"time":1300,"data":{"turn":13}}"#,
            #"{"type":"step/start","seq":131,"time":1310,"data":{"turn":13,"step":1}}"#,
            #"{"type":"assistant/message","seq":132,"time":1320,"data":{"turn":13,"step":1,"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"reasoning","text":"想一想"},{"type":"text","text":"结论如下\n就是这样。"}]}}}"#,
            #"{"type":"step/end","seq":133,"time":1330,"data":{"turn":13,"step":1}}"#,
            #"{"type":"turn/end","seq":134,"time":1340,"data":{"turn":13,"reason":{"kind":"completed"}}}"#,
        ])
        expect(messages(in: answer.nodes).count == 1, "A9a 出一条最终答案消息")
        expect(messages(in: answer.nodes).first?.text == "结论如下\n就是这样。", "A9b 答案正文完整保留")
        expect(processes(in: answer.nodes).first?.entries.contains { if case .text = $0 { return true }; return false } == false, "A9c 答案不重复出现在过程里")

        // A9d：含工具调用的消息**不是**答案 —— 哪怕它有文本。它的文本进过程。
        let toolish = assemble([
            #"{"type":"turn/start","seq":140,"time":1400,"data":{"turn":14}}"#,
            #"{"type":"step/start","seq":141,"time":1410,"data":{"turn":14,"step":1}}"#,
            #"{"type":"assistant/message","seq":142,"time":1420,"data":{"turn":14,"step":1,"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"text","text":"我去查一下"},{"type":"tool-call","id":"call_x","name":"bash","arguments":"{}"}]}}}"#,
            #"{"type":"tool/call","seq":143,"time":1430,"data":{"turn":14,"step":1,"callId":"call_x","name":"bash","arguments":"{}"}}"#,
            #"{"type":"step/end","seq":144,"time":1440,"data":{"turn":14,"step":1}}"#,
            #"{"type":"turn/end","seq":145,"time":1450,"data":{"turn":14,"reason":{"kind":"completed"}}}"#,
        ])
        expect(messages(in: toolish.nodes).isEmpty, "A9d 含工具调用的消息不出答案")
        expect(processes(in: toolish.nodes).first?.entries.contains { if case .text(let _, let text, _) = $0 { return text == "我去查一下" }; return false } == true, "A9e 它的文本进过程")

        // A9f：该轮**最后一个 step 没有助手消息**（比如最后一步刚开就出事）→
        //      这一轮没有答案 —— 不能拿前面 step 说过的话冒充最终回答。
        let noAnswer = assemble([
            #"{"type":"turn/start","seq":150,"time":1500,"data":{"turn":15}}"#,
            #"{"type":"step/start","seq":151,"time":1510,"data":{"turn":15,"step":1}}"#,
            #"{"type":"assistant/message","seq":152,"time":1520,"data":{"turn":15,"step":1,"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"text","text":"中间说过的话"}]}}}"#,
            #"{"type":"step/end","seq":153,"time":1530,"data":{"turn":15,"step":1}}"#,
            #"{"type":"step/start","seq":154,"time":1540,"data":{"turn":15,"step":2}}"#,
            #"{"type":"turn/end","seq":155,"time":1550,"data":{"turn":15,"reason":{"kind":"error"}}}"#,
        ])
        expect(messages(in: noAnswer.nodes).isEmpty, "A9f 最后一步没有消息 → 本轮没有答案")
        expect(processes(in: noAnswer.nodes).first?.entries.contains { if case .text(let _, let text, _) = $0 { return text == "中间说过的话" }; return false } == true, "A9g 它落进过程，不丢")

        // A3 的补充：一轮里多步 —— 前一步收口只该影响那一步的调用，
        // 不能把后一步还在跑的也一起判成中断（否则「上一步超时」会连累整轮）。
        report = assemble([
            #"{"type":"turn/start","seq":160,"time":1600,"data":{"turn":16}}"#,
            #"{"type":"step/start","seq":161,"time":1610,"data":{"turn":16,"step":1}}"#,
            #"{"type":"tool/call","seq":162,"time":1620,"data":{"turn":16,"step":1,"callId":"c9","name":"bash","arguments":"{}"}}"#,
            #"{"type":"step/end","seq":163,"time":1630,"data":{"turn":16,"step":1}}"#,
            #"{"type":"step/start","seq":164,"time":1640,"data":{"turn":16,"step":2}}"#,
            #"{"type":"tool/call","seq":165,"time":1650,"data":{"turn":16,"step":2,"callId":"c10","name":"bash","arguments":"{}"}}"#,
        ])
        rows = toolRows(in: report.nodes)
        expect(rows.count == 2, "A3d 两步的调用都出")
        expect(rows[0].status == .interrupted, "A3e 已收口那一步的调用 → 中断")
        expect(rows[1].status == .running, "A3f 后一步还在跑 → 不被前一步连累")

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
        expect(order == ["思考:先想想", "工具:d1", "思考:再想想", "工具:d2"], "A5 交替顺序 = 事件顺序")

        // A6：折叠头上的一句话。计数为 0 的不写出来，只有思考时写兜底文案。
        expect(processes(in: interleaved.nodes).first?.summary == "2 次工具调用", "A6a 只有工具调用 → 只写工具数")

        let mixed = assemble([
            #"{"type":"turn/start","seq":180,"time":1800,"data":{"turn":18}}"#,
            #"{"type":"step/start","seq":181,"time":1810,"data":{"turn":18,"step":1}}"#,
            #"{"type":"tool/call","seq":182,"time":1820,"data":{"turn":18,"step":1,"callId":"e1","name":"bash","arguments":"{}"}}"#,
            #"{"type":"assistant/message","seq":183,"time":1830,"data":{"turn":18,"step":1,"message":{"content":[{"type":"text","text":"我看一下"},{"type":"tool-call","id":"e2","name":"glob","arguments":"{}"}]}}}"#,
            #"{"type":"tool/call","seq":184,"time":1840,"data":{"turn":18,"step":1,"callId":"e2","name":"glob","arguments":"{}"}}"#,
        ])
        expect(processes(in: mixed.nodes).first?.summary == "2 次工具调用 · 1 条消息", "A6b 工具与中间文本并列")

        let thinking = assemble([
            #"{"type":"turn/start","seq":190,"time":1900,"data":{"turn":19}}"#,
            #"{"type":"step/start","seq":191,"time":1910,"data":{"turn":19,"step":1}}"#,
            #"{"type":"assistant/message","seq":192,"time":1920,"data":{"turn":19,"step":1,"message":{"content":[{"type":"reasoning","text":"只是想了一下"}]}}}"#,
            #"{"type":"step/end","seq":193,"time":1930,"data":{"turn":19,"step":1}}"#,
        ])
        expect(processes(in: thinking.nodes).first?.summary == "已思考", "A6c 只有思考 → 兜底文案，不写 0 次工具调用")

        let empty = assemble([
            #"{"type":"turn/start","seq":200,"time":2000,"data":{"turn":20}}"#,
            #"{"type":"step/start","seq":201,"time":2010,"data":{"turn":20,"step":1}}"#,
            #"{"type":"step/end","seq":202,"time":2020,"data":{"turn":20,"step":1}}"#,
        ])
        expect(processes(in: empty.nodes).isEmpty, "A6d 三者皆空 → 不画这一行")

        // A7e：**用户消息夹在 `turn/start` 与助手的首个输出之间** —— 这是真实会话的
        //      常态（真机日志里 13 个 `turn/start` 全被这么夹着）。那一句要排到过程
        //      前面（顺序），但这一轮远没结束，所以「有头」的身份不能被一起收掉。
        let interleavedInput = assemble([
            #"{"type":"turn/start","seq":210,"time":2100,"data":{"turn":21}}"#,
            #"{"type":"step/start","seq":211,"time":2110,"data":{"turn":21,"step":1}}"#,
            #"{"type":"user/message","seq":212,"time":2120,"data":{"role":"user","source":{"kind":"user"},"content":[{"type":"text","text":"帮我看看"}]}}"#,
            #"{"type":"assistant/message","seq":213,"time":2130,"data":{"turn":21,"step":1,"message":{"role":"assistant","source":{"kind":"assistant"},"content":[{"type":"reasoning","text":"嗯"},{"type":"text","text":"看完了"}]}}}"#,
            #"{"type":"turn/end","seq":214,"time":2140,"data":{"turn":21,"reason":{"kind":"completed"}}}"#,
        ])
        expect(processes(in: interleavedInput.nodes).first?.hasHeader == true, "A7e 输入夹在中间也不该把这一组判成无头")
        expect(messages(in: interleavedInput.nodes).first?.text == "帮我看看", "A7f 那句用户消息排在过程之前")

        print("—— \(passed) passed, \(failed) failed ——")
        if failed > 0 { exit(1) }
    }
}

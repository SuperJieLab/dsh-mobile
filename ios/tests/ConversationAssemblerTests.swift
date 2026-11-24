/**
 * 会话组装的引擎判据 —— 坐标、增量与全量一致、前插只增不改、定稿不换身份。
 *
 * 这些判据守的是「身份与内容分离」这一次结构位移：它们红了，说明某一处又按 `seq` 发身份证了。
 */
import XCTest

@testable import DshMobile

final class ConversationAssemblerTests: XCTestCase {

    // MARK: - 造事件

    private func event(_ seq: Int, _ type: String, _ json: String = "{}") -> AssemblyEvent {
        let data = try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return AssemblyEvent(order: Double(seq), seq: seq, type: type, time: Double(seq), data: data)
    }

    /// 未定稿帧：没有 `seq`，只有客户端编的小数位置。
    private func chunk(_ order: Double, turn: Int, step: Int, index: Int, text: String) -> AssemblyEvent {
        let json = """
        {"attemptId":"a1","turn":\(turn),"step":\(step),\
        "chunk":{"type":"text-delta","index":\(index),"text":"\(text)"}}
        """
        let data = try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return AssemblyEvent(order: order, seq: nil, type: "assistant/live-chunk", time: order, data: data)
    }

    private func assembler() -> ConversationAssembler {
        ConversationAssembler(definitions: [
            AnyNodeDefinition(AssistantStepDefinition()),
            AnyNodeDefinition(MessageDefinition()),
            AnyNodeDefinition(ProcessDefinition()),
            AnyNodeDefinition(CommandDefinition()),
        ])
    }

    /// 比较用的内容指纹：过程节点只看「哪一轮 + 条目」，不看 `hasHeader`
    /// —— 后者随窗口边界变，是正确行为而不是漂移。
    private static func content(_ data: ChatNodeData?) -> String {
        guard case .process(let process)? = data else { return String(describing: data) }
        return "process|\(process.turn)|\(process.segment.entries)"
    }

    private func keyed(_ nodes: [ChatNode]) -> [String: ChatNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.key, $0) })
    }

    /// 屏幕上那一列的顺序 —— 排序在 `ChatSnapshotBuilder` 里，直接看 `nodes()` 是字典顺序。
    private func ordered(_ assembler: ConversationAssembler) -> [ChatNode] {
        var builder = ChatSnapshotBuilder()
        return builder.replace(assembler.nodes()).visibleNodes
    }

    // MARK: - O2 坐标

    func testLocationTracksBoundaries() {
        let events = [
            event(1, "turn/start", #"{"turn":3}"#),
            event(2, "step/start", #"{"turn":3,"step":1}"#),
            event(3, "tool/call", #"{"turn":3,"step":1,"callId":"c1","name":"read"}"#),
            event(4, "step/end", #"{"turn":3,"step":1}"#),
            event(5, "turn/end", #"{"turn":3,"reason":"done"}"#),
        ]
        var index = LocationIndex()
        index.rebuild(events)

        XCTAssertEqual(index.locationOf(events[0]).turnNumber, 3)
        XCTAssertNil(index.locationOf(events[0]).stepNumber)
        XCTAssertEqual(index.locationOf(events[1]).stepNumber, 1)
        XCTAssertEqual(index.locationOf(events[2]).stepNumber, 1)
        XCTAssertEqual(index.locationOf(events[3]).closedBoundary?.order, 4)
        XCTAssertEqual(index.locationOf(events[4]).closedBoundary?.order, 5)
    }

    // MARK: - O3 增量与全量同结果

    func testAppendMatchesReplace() {
        let events = sampleEvents()
        var appended = assembler()
        for item in events { appended.append(item) }
        var replaced = assembler()
        replaced.rebuild(events)

        XCTAssertFalse(replaced.nodes().isEmpty, "样本一条节点都没出 —— 这条判据在拿两个空集合互比")
        XCTAssertEqual(appended.nodes().map(\.key).sorted(), replaced.nodes().map(\.key).sorted())
        XCTAssertEqual(keyed(appended.nodes()), keyed(replaced.nodes()))
    }

    // MARK: - O4 前插只增不改

    func testPrependKeepsExistingNodes() {
        let events = sampleEvents()
        var full = assembler()
        full.rebuild(events)
        let expected = keyed(full.nodes())

        var preparer = assembler()
        preparer.rebuild(Array(events.suffix(from: 12)))
        let before = keyed(preparer.nodes())
        preparer.prepend(Array(events.prefix(12)))

        // 前插前已经存在的节点：身份、位置、条目都不变。
        // 唯一允许变的是「这一轮的开头是否在窗口里」—— 前插补齐 `turn/start` 时它本来就该变，
        // 边界形态随窗口变化，这本身就是正确行为。
        XCTAssertFalse(before.isEmpty)
        for (key, node) in before {
            let after = keyed(preparer.nodes())[key]
            XCTAssertEqual(after?.anchorSeq, node.anchorSeq, "前插后 \(key) 的位置变了")
            XCTAssertEqual(after?.businessId, node.businessId, "前插后 \(key) 的业务标识变了")
            XCTAssertEqual(Self.content(after?.data), Self.content(node.data), "前插后 \(key) 的内容变了")
        }

        // 前插补齐的更早内容也要进来 —— 与全量重算逐条对齐。
        // 只比「前插前已存在的 key」会漏掉一条：那个 key 在窗口里还没有 start，所以还没有节点，
        // 而前插补上的 start 恰好该把它带出来（或该把已有条目接上去）。第一版判据漏的就是这条。
        let after = keyed(preparer.nodes())
        XCTAssertEqual(after.keys.sorted(), expected.keys.sorted(), "前插后的节点集合与全量重算不同")
        for (key, node) in expected {
            XCTAssertEqual(after[key]?.data, node.data, "前插后的 \(key) 与全量重算不同")
        }
    }

    // MARK: - O5 工具行配对

    func testToolResultFirstThenCallFillsName() {
        let events = [
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "step/start", #"{"turn":1,"step":1}"#),
            event(3, "tool/result",
                  #"{"turn":1,"step":1,"message":{"source":{"callId":"c1"},"content":[{"type":"tool-result","content":[{"type":"text","text":"ok"}]}]}}"#),
            event(4, "tool/call", #"{"turn":1,"step":1,"callId":"c1","name":"read","arguments":"{}"}"#),
        ]
        var assembler = assembler()
        assembler.rebuild(events)

        guard let node = assembler.nodes().first(where: { $0.businessId == "1" }),
              case .process(let data) = node.data else {
            return XCTFail("没有过程节点")
        }
        let rows = data.segment.entries.compactMap { entry -> ToolRow? in
            if case .tool(let row) = entry { return row }
            return nil
        }
        XCTAssertEqual(rows.count, 1, "结果先到、调用后到，应该只有一行")
        XCTAssertEqual(rows.first?.name, "read", "后到的调用没把名字补上")
        XCTAssertEqual(rows.first?.status, ToolRow.Status.succeeded)
        XCTAssertEqual(rows.first?.resultText, "ok", "结果正文套了一层 tool-result，没下钻就永远是空")
    }

    // MARK: - O6 定稿不换身份

    func testSettlementKeepsNodeIdentity() {
        let events = [
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "step/start", #"{"turn":1,"step":1}"#),
            chunk(3.1, turn: 1, step: 1, index: 0, text: "he"),
            chunk(3.2, turn: 1, step: 1, index: 0, text: "llo"),
            event(4, "assistant/message",
                  #"{"turn":1,"step":1,"message":{"id":"m1","content":[{"type":"text","text":"hello"}]}}"#),
            event(5, "step/end", #"{"turn":1,"step":1}"#),
        ]
        var assembler = assembler()
        for item in events { assembler.append(item) }

        let assistant = assembler.nodes().first { $0.kind == "assistant-step" }
        XCTAssertEqual(assistant?.businessId, "1:1", "业务标识不是 turn:step")
        guard case .assistant(let data)? = assistant?.data else { return XCTFail("没有助手节点") }
        XCTAssertEqual(data.status, AssistantNodeData.Status.settled)
        XCTAssertEqual(data.text, "hello")
        XCTAssertEqual(assistant?.visibility, NodeVisibility.visible)
    }

    /// 流式进行中就该有节点，且它和定稿后是同一个 key。
    func testStreamingNodeExistsBeforeSettlement() {
        let head = [
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "step/start", #"{"turn":1,"step":1}"#),
            chunk(3.1, turn: 1, step: 1, index: 0, text: "he"),
        ]
        var assembler = assembler()
        for item in head { assembler.append(item) }
        let before = assembler.nodes().first { $0.kind == "assistant-step" }
        XCTAssertNotNil(before)

        assembler.append(event(4, "assistant/message",
                               #"{"turn":1,"step":1,"message":{"id":"m1","content":[{"type":"text","text":"hello"}]}}"#))
        let after = assembler.nodes().first { $0.kind == "assistant-step" }
        XCTAssertEqual(before?.key, after?.key, "定稿换了节点身份")
    }

    // MARK: - O7 一轮一个过程节点

    func testProcessIsOneNodePerTurn() {
        let events = [
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "user/message", #"{"id":"u1","source":{"kind":"user"},"content":[{"type":"text","text":"开"}]}"#),
            event(3, "step/start", #"{"turn":1,"step":1}"#),
            event(4, "tool/call", #"{"turn":1,"step":1,"callId":"c1","name":"read","arguments":"{}"}"#),
            event(5, "tool/result",
                  #"{"turn":1,"step":1,"message":{"source":{"callId":"c1"},"content":[{"type":"text","text":"ok"}]}}"#),
            event(6, "assistant/message",
                  #"{"turn":1,"step":1,"message":{"id":"m1","content":[{"type":"text","text":"中间说明"}]}}"#),
            event(7, "step/end", #"{"turn":1,"step":1}"#),
            event(8, "step/start", #"{"turn":1,"step":2}"#),
            event(9, "assistant/message",
                  #"{"turn":1,"step":2,"message":{"id":"m2","content":[{"type":"text","text":"最终回答"}]}}"#),
            event(10, "step/end", #"{"turn":1,"step":2}"#),
            event(11, "turn/end", #"{"turn":1,"reason":"done"}"#),
        ]
        var assembler = assembler()
        assembler.rebuild(events)

        let processes = assembler.nodes().filter { $0.kind == "process" }
        XCTAssertEqual(processes.count, 1, "一轮里出现了多个过程节点")
        guard case .process(let data)? = processes.first?.data else { return XCTFail("没有过程节点") }
        XCTAssertEqual(data.turn, 1)

        let entries = data.segment.entries
        let texts = entries.compactMap { entry -> String? in
            if case .text(_, _, _, let text, _) = entry { return text }
            return nil
        }
        XCTAssertTrue(texts.contains("中间说明"), "中间步的文本没进过程")
        XCTAssertFalse(texts.contains("最终回答"), "答案不该在过程里再画一遍")
    }

    /// 草稿比 `step/start` 先到（前插补齐、或帧序有偏）：不能把整格丢掉。
    /// 修之前这里 state 永久为 nil，Release 里一句话都没有，表现是整段少一行。
    func testDraftBeforeStepStartStillRenders() {
        var assembler = assembler()
        assembler.append(chunk(1.5, turn: 1, step: 1, index: 0, text: "先到的草稿"))
        assembler.append(event(2, "turn/start", #"{"turn":1}"#))
        assembler.append(event(3, "step/start", #"{"turn":1,"step":1}"#))

        guard let node = assembler.nodes().first(where: { $0.kind == "assistant-step" }),
              case .assistant(let data) = node.data else { return XCTFail("草稿整格丢了") }
        XCTAssertEqual(data.text, "先到的草稿")
    }

    /// 列表身份必须是引擎给的 `key`：业务 id 跨 kind 会撞号（消息 id 与轮次号同形）。
    func testNodeIdentityIsEngineKey() {
        // 消息 id 故意叫 "1"，与本轮轮次号同形。
        let events = [
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "user/message", #"{"id":"1","source":{"kind":"user"},"content":[{"type":"text","text":"问"}]}"#),
            event(3, "step/start", #"{"turn":1,"step":1}"#),
            event(4, "tool/call", #"{"turn":1,"step":1,"callId":"c1","name":"read"}"#),
        ]
        var assembler = assembler()
        assembler.rebuild(events)

        let nodes = assembler.nodes()
        XCTAssertEqual(Set(nodes.map(\.id)).count, nodes.count, "列表身份有重复")
        let message = nodes.first { $0.kind == "message" }
        let process = nodes.first { $0.kind == "process" }
        XCTAssertEqual(message?.businessId, "1")
        XCTAssertEqual(process?.businessId, "1", "两个 kind 的业务标识本来就撞了")
        XCTAssertNotEqual(message?.id, process?.id, "撞号的业务标识被当成了列表身份")
    }

    /// 窗口首条就是定稿事件（往回翻的切点落在它上面）：这一步没有 `step/start`，
    /// 回答也必须画出来 —— 引擎建不出 state 时要按已收命中重放。
    func testAnswerWithoutStepStartStillRenders() {
        let only = event(10, "assistant/message",
                         #"{"turn":1,"step":2,"message":{"id":"m9","content":[{"type":"text","text":"只有我"}]}}"#)
        var assembler = assembler()
        assembler.rebuild([only])

        guard let node = assembler.nodes().first(where: { $0.kind == "assistant-step" }),
              case .assistant(let data) = node.data else { return XCTFail("没有 step/start 时回答整段消失了") }
        XCTAssertEqual(data.text, "只有我")
        XCTAssertEqual(node.visibility, NodeVisibility.visible)
        XCTAssertNil(assembler.nodes().first { $0.kind == "process" }, "同一段又画了一遍过程")
    }

    /// 只有 `command/done` 在窗口里，往回翻补上 `command/run`：
    /// 仍是同一行、名字补上，位置前移到按下的那一刻。
    func testCommandGainsItsRunOnPrepend() {
        var assembler = assembler()
        assembler.rebuild([event(5, "command/done", #"{"commandId":"c1","kind":"success","text":"ok"}"#)])
        let before = assembler.nodes().first { $0.kind == "command" }
        XCTAssertEqual(before?.anchorSeq, 5)

        assembler.prepend([event(3, "command/run", #"{"commandId":"c1","name":"compact","args":"-f"}"#)])
        let rows = assembler.nodes().filter { $0.kind == "command" }
        XCTAssertEqual(rows.count, 1, "补上 run 后多出一行")
        XCTAssertEqual(rows.first?.anchorSeq, 3, "位置没有回到按下的那一刻")
        guard case .command(let command)? = rows.first?.data else { return XCTFail("没有命令节点") }
        XCTAssertEqual(command.name, "compact")
        XCTAssertEqual(command.outcome, CommandOutcome.success("ok"))
    }

    // MARK: - 收笔与中断

    /// 收笔点名：撤掉草稿、接上定稿，身份不变、内容换成定稿那份。
    func testSettleAppliesNamedSettlement() {
        var assembler = assembler()
        assembler.append(event(1, "turn/start", #"{"turn":1}"#))
        assembler.append(event(2, "step/start", #"{"turn":1,"step":1}"#))
        assembler.append(chunk(3.5, turn: 1, step: 1, index: 0, text: "半句"))

        assembler.settleAssistant(
            attemptId: "a1",
            settlement: event(4, "assistant/message",
                              #"{"turn":1,"step":1,"message":{"id":"m1","content":[{"type":"text","text":"完整回答"}]}}"#)
        )

        guard let node = assembler.nodes().first(where: { $0.kind == "assistant-step" }),
              case .assistant(let data) = node.data else { return XCTFail("收笔后没有助手节点") }
        XCTAssertEqual(data.text, "完整回答", "定稿没接上")
        XCTAssertEqual(data.status, AssistantNodeData.Status.settled)
        XCTAssertEqual(node.businessId, "1:1", "收笔换了身份")
    }

    /// 被放弃的一轮：草稿整批撤掉，节点仍在（转 hidden），身份不删。
    func testSettleWithoutSettlementKeepsIdentity() {
        var assembler = assembler()
        assembler.append(event(1, "turn/start", #"{"turn":1}"#))
        assembler.append(event(2, "step/start", #"{"turn":1,"step":1}"#))
        assembler.append(chunk(3.5, turn: 1, step: 1, index: 0, text: "半句"))
        let before = assembler.nodes().first { $0.kind == "assistant-step" }
        XCTAssertNotNil(before)

        assembler.settleAssistant(attemptId: "a1")
        let after = assembler.nodes().first { $0.kind == "assistant-step" }
        XCTAssertEqual(after?.businessId, before?.businessId, "撤销草稿把节点一起删了")
        XCTAssertEqual(after?.visibility, NodeVisibility.hidden, "没有内容了却还画着")
    }

    /// 失败 attempt 的紧凑流：已流出的文字要留下，标成中断。
    func testFailedAttemptKeepsItsText() {
        var assembler = assembler()
        assembler.append(event(1, "turn/start", #"{"turn":1}"#))
        assembler.append(event(2, "step/start", #"{"turn":1,"step":1}"#))
        assembler.append(chunk(3.5, turn: 1, step: 1, index: 0, text: "半"))

        // 定稿交的是**完整紧凑流**，不是最后一段 delta。
        let attempt = event(4, "assistant/attempt",
                            #"{"turn":1,"step":1,"stream":[{"type":"text-chunks","time0":3500,"index":0,"dt":[500],"texts":["半","句"]}]}"#)
        assembler.settleAssistant(attemptId: "a1", settlement: attempt)

        guard let node = assembler.nodes().first(where: { $0.kind == "assistant-step" }),
              case .assistant(let data) = node.data else { return XCTFail("失败 attempt 之后没有助手节点") }
        XCTAssertEqual(data.text, "半句", "已流出的文字丢了")
        XCTAssertEqual(data.status, AssistantNodeData.Status.interrupted)
    }

    /// 重试：这一步的可见内容整份退掉，只留重试后的输出。
    func testRetryClearsPreviousContent() {
        var assembler = assembler()
        assembler.append(event(1, "turn/start", #"{"turn":1}"#))
        assembler.append(event(2, "step/start", #"{"turn":1,"step":1}"#))
        assembler.append(chunk(3.5, turn: 1, step: 1, index: 0, text: "第一次"))
        assembler.append(event(4, "llm/retry", #"{"turn":1,"step":1}"#))
        assembler.append(chunk(5.5, turn: 1, step: 1, index: 0, text: "第二次"))

        guard let node = assembler.nodes().first(where: { $0.kind == "assistant-step" }),
              case .assistant(let data) = node.data else { return XCTFail("重试后没有助手节点") }
        XCTAssertEqual(data.text, "第二次", "重试没把上一版内容退掉")
    }

    /// 一步关上时，还在跑的工具行标中断 —— 它不会有结果了。
    func testStepEndInterruptsRunningTool() {
        var assembler = assembler()
        assembler.rebuild([
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "step/start", #"{"turn":1,"step":1}"#),
            event(3, "tool/call", #"{"turn":1,"step":1,"callId":"c1","name":"read","arguments":"{}"}"#),
            event(4, "step/end", #"{"turn":1,"step":1}"#),
        ])
        guard let node = assembler.nodes().first(where: { $0.kind == "process" }),
              case .process(let data) = node.data else { return XCTFail("没有过程节点") }
        let rows = data.segment.entries.compactMap { entry -> ToolRow? in
            if case .tool(let row) = entry { return row }
            return nil
        }
        XCTAssertEqual(rows.first?.status, ToolRow.Status.interrupted)
    }

    // MARK: - 顺序

    /// 一轮的顺序：提问 → 过程（思考）→ 回复。过程锚在 `turn/start` 上时，思考会跑到提问上面去。
    func testProcessSitsBetweenQuestionAndAnswer() {
        let events = [
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "user/message", #"{"id":"u1","source":{"kind":"user"},"content":[{"type":"text","text":"问"}]}"#),
            event(3, "step/start", #"{"turn":1,"step":1}"#),
            event(4, "assistant/message",
                  #"{"turn":1,"step":1,"message":{"id":"m1","content":[{"type":"reasoning","text":"想一想"},{"type":"text","text":"答"}]}}"#),
            event(5, "step/end", #"{"turn":1,"step":1}"#),
        ]
        var assembler = assembler()
        assembler.rebuild(events)

        let kinds = ordered(assembler).map(\.kind)
        XCTAssertEqual(kinds, ["message", "process", "assistant-step"], "顺序不是 提问 → 过程 → 回复")
    }

    // MARK: - 命令

    /// `command/run` 与 `command/done` 落在同一行：结果到达是原地更新，不是新起一行。
    func testCommandPairsOnOneRow() {
        let run = event(1, "command/run", #"{"commandId":"c1","name":"compact","args":"--all"}"#)
        var assembler = assembler()
        assembler.append(event(0, "turn/start", #"{"turn":1}"#))
        assembler.append(run)
        let started = assembler.nodes().filter { $0.kind == "command" }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.businessId, "c1")

        assembler.append(event(2, "command/done", #"{"commandId":"c1","kind":"success","text":"ok"}"#))
        let settled = assembler.nodes().filter { $0.kind == "command" }
        XCTAssertEqual(settled.count, 1, "结果到达新起了一行")
        XCTAssertEqual(settled.first?.key, started.first?.key, "结果到达换了身份")
        guard case .command(let command)? = settled.first?.data else { return XCTFail("没有命令节点") }
        XCTAssertEqual(command.name, "compact")
        XCTAssertEqual(command.outcome, CommandOutcome.success("ok"))
    }

    /// 只有 `command/done` 在窗口里（往回翻切掉了 `run`）：照样出一行，但名字不编。
    func testCommandWithoutRunStillShows() {
        var assembler = assembler()
        assembler.rebuild(
            [event(1, "command/done", #"{"commandId":"c9","kind":"error","text":"boom"}"#)]
        )
        let commands = assembler.nodes().filter { $0.kind == "command" }
        XCTAssertEqual(commands.count, 1)
        guard case .command(let command)? = commands.first?.data else { return XCTFail("没有命令节点") }
        XCTAssertEqual(command.name, "", "不知道命令名却编了一个")
        XCTAssertEqual(command.outcome, CommandOutcome.failure("boom"))
    }

    /// 一步里说过两次：只有最后一条是答案，前一条留在过程里 —— 不丢话。
    func testEarlierTextInSameStepStaysInProcess() {
        let events = [
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "step/start", #"{"turn":1,"step":1}"#),
            event(3, "assistant/message",
                  #"{"turn":1,"step":1,"message":{"id":"m1","content":[{"type":"text","text":"我先说一句"}]}}"#),
            event(4, "assistant/message",
                  #"{"turn":1,"step":1,"message":{"id":"m2","content":[{"type":"text","text":"这才是答案"}]}}"#),
            event(5, "step/end", #"{"turn":1,"step":1}"#),
        ]
        var assembler = assembler()
        assembler.rebuild(events)

        guard let process = assembler.nodes().first(where: { $0.kind == "process" }),
              case .process(let data) = process.data else { return XCTFail("没有过程节点") }
        let texts = data.segment.entries.compactMap { entry -> String? in
            if case .text(_, _, _, let text, _) = entry { return text }
            return nil
        }
        XCTAssertEqual(texts, ["我先说一句"], "同一步更早的那句话丢了")

        guard let assistant = assembler.nodes().first(where: { $0.kind == "assistant-step" }),
              case .assistant(let answer) = assistant.data else { return XCTFail("没有助手节点") }
        XCTAssertEqual(answer.text, "这才是答案")
    }

    // MARK: - 样本

    /// 两轮、各两步，含工具调用与一次流式输出 —— 覆盖三条路径的常用形状。
    private func sampleEvents() -> [AssemblyEvent] {
        var events: [AssemblyEvent] = []
        var seq = 1
        func add(_ type: String, _ json: String = "{}") {
            events.append(event(seq, type, json))
            seq += 1
        }
        add("turn/start", #"{"turn":1}"#)
        add("user/message", #"{"id":"u1","source":{"kind":"user"},"content":[{"type":"text","text":"开"}]}"#)
        add("step/start", #"{"turn":1,"step":1}"#)
        add("tool/call", #"{"turn":1,"step":1,"callId":"c1","name":"read","arguments":"{\"path\":\"a\"}"}"#)
        add("tool/result",
            #"{"turn":1,"step":1,"message":{"source":{"callId":"c1"},"content":[{"type":"text","text":"ok"}]}}"#)
        add("assistant/message",
            #"{"turn":1,"step":1,"message":{"id":"m1","content":[{"type":"text","text":"中间"}]}}"#)
        add("step/end", #"{"turn":1,"step":1}"#)
        add("step/start", #"{"turn":1,"step":2}"#)
        add("assistant/message",
            #"{"turn":1,"step":2,"message":{"id":"m2","content":[{"type":"text","text":"回答一"}]}}"#)
        add("step/end", #"{"turn":1,"step":2}"#)
        add("turn/end", #"{"turn":1,"reason":"done"}"#)
        add("turn/start", #"{"turn":2}"#)
        add("user/message", #"{"id":"u2","source":{"kind":"user"},"content":[{"type":"text","text":"再问"}]}"#)
        add("step/start", #"{"turn":2,"step":1}"#)
        add("tool/call", #"{"turn":2,"step":1,"callId":"c2","name":"grep","arguments":"{}"}"#)
        add("tool/result",
            #"{"turn":2,"step":1,"message":{"source":{"callId":"c2"},"isError":true,"content":[{"type":"text","text":"no"}]}}"#)
        add("assistant/message",
            #"{"turn":2,"step":1,"message":{"id":"m3","content":[{"type":"text","text":"回答二"}]}}"#)
        add("step/end", #"{"turn":2,"step":1}"#)
        add("turn/end", #"{"turn":2,"reason":"done"}"#)
        events.append(chunk(19.5, turn: 3, step: 1, index: 0, text: "流式"))
        events.append(event(20, "turn/start", #"{"turn":3}"#))
        events.append(event(21, "step/start", #"{"turn":3,"step":1}"#))
        return events
    }

    // MARK: - 每次写入报出「变了哪些槽位」

    func testAppendingAUserMessageTouchesExactlyOneSlot() {
        var engine = assembler()
        engine.rebuild([event(1, "turn/start", #"{"turn":1}"#)])

        let change = engine.append(
            event(2, "user/message", #"{"id":"u1","source":{"kind":"user"},"content":[{"type":"text","text":"开"}]}"#)
        )

        XCTAssertFalse(change.rebuilt, "一条非边界事件说得清自己变了哪些槽位")
        XCTAssertEqual(change.touched.count, 1, "只有这条消息自己的格子")
    }

    func testAppendingAnAssistantMessageTouchesTheStepAndTheTurnProcess() {
        var engine = assembler()
        engine.rebuild([
            event(1, "turn/start", #"{"turn":1}"#),
            event(3, "step/start", #"{"turn":1,"step":1}"#),
        ])

        let change = engine.append(event(6, "assistant/message",
                                         #"{"turn":1,"step":1,"message":{"id":"m1","content":[{"type":"text","text":"说明"}]}}"#))

        XCTAssertFalse(change.rebuilt)
        XCTAssertEqual(change.touched.count, 2,
                       "一条助手消息同时属于这一轮的过程行与这一格的步骤行")
    }

    func testAppendingABoundaryEventSaysItCannotNameTheChangeSet() {
        var engine = assembler()
        engine.rebuild([
            event(1, "turn/start", #"{"turn":1}"#),
            event(3, "step/start", #"{"turn":1,"step":1}"#),
        ])

        let change = engine.append(event(7, "step/end", #"{"turn":1,"step":1}"#))

        XCTAssertTrue(change.rebuilt,
                      "边界事件会重建位置索引，改到的是任意槽位 —— 变化集说不清")
    }

    func testPrependingSaysItCannotNameTheChangeSet() {
        var engine = assembler()
        engine.rebuild([event(9, "turn/start", #"{"turn":1}"#)])

        let change = engine.prepend([
            event(1, "turn/start", #"{"turn":1}"#),
            event(2, "user/message", #"{"id":"u0","source":{"kind":"user"},"content":[{"type":"text","text":"早"}]}"#),
        ])

        XCTAssertTrue(change.rebuilt, "前插会重建位置索引")
    }
}

/**
 * 一次命令在屏幕上的那一行 —— 先按了什么，后来结果如何。
 *
 * 身份是 `commandId`：`command/run` 与 `command/done` 靠它配对，结果到达时原地更新。
 * 用 `seq` 当身份会让这一行在结果到达时重挂载：结果到达时它换了一个 id，列表只能删一建一。
 *
 * 只有 `done` 落在窗口里时（往回翻切掉了 `run`），这一行照样出，但名字与参数留空 ——
 * 不编一个。
 */
import Foundation

struct CommandRun: Equatable {
    let commandId: String
    let name: String
    let args: String?
    var outcome: CommandOutcome?

    /// 那一行上「命令是什么」那半句：名字 + 原样参数（参数缺席就只有名字）。
    var invocation: String {
        guard let args, !args.isEmpty else { return "/\(name)" }
        return "/\(name) \(args)"
    }
}

/// 一次命令执行的结局。
enum CommandOutcome: Equatable {
    case success(String?)
    case failure(String?)
}

struct CommandDefinition: ConversationNodeDefinition {

    struct State: Equatable {
        var run: CommandRun
    }

    let kind = "command"

    func match(_ event: AssemblyEvent) -> MatchResult? {
        guard let commandId = event.data["commandId"]?.string else { return nil }
        switch event.type {
        case "command/run", "command/done":
            // 两条都标成 start：最早的那条初始化，后一条自然走 update。
            // 这样「只有 done 在窗口里」也能出一行，不必为它另开一条分支。
            return MatchResult(id: commandId, role: .start)
        default:
            return nil
        }
    }

    func start(_ context: NodeContext<State>, _ match: ConversationMatch) -> State {
        State(run: Self.run(from: match.event))
    }

    func update(_ context: NodeContext<State>, _ match: ConversationMatch) -> State {
        guard var state = context.state else { return start(context, match) }
        if let outcome = Self.outcome(from: match.event) {
            state.run.outcome = outcome
        }
        return state
    }

    func buildViewNode(_ context: NodeContext<State>) -> ChatNode? {
        guard let state = context.state else { return context.current.map(Self.hidden) }
        let anchor = context.start?.event.order ?? context.matches.first?.event.order ?? 0
        return ChatNode(
            key: context.key,
            kind: kind,
            businessId: context.id,
            anchorSeq: anchor,
            visibility: .visible,
            data: .command(state.run)
        )
    }

    /// 只有 `run` 带着名字与参数；`done` 只带结局。
    static func run(from event: AssemblyEvent) -> CommandRun {
        CommandRun(
            commandId: event.data["commandId"]?.string ?? "",
            name: event.type == "command/run" ? (event.data["name"]?.string ?? "") : "",
            args: event.type == "command/run" ? event.data["args"]?.string : nil,
            outcome: outcome(from: event)
        )
    }

    /// 只有上游明说 success 才算成功；别的取值（含将来新增的）一律按失败显示 ——
    /// 「以为成功了其实没有」比「以为失败其实成功」代价大。
    static func outcome(from event: AssemblyEvent) -> CommandOutcome? {
        guard event.type == "command/done", let kind = event.data["kind"]?.string else { return nil }
        let text = event.data["text"]?.string
        return kind == "success" ? .success(text) : .failure(text)
    }

    static func hidden(_ node: ChatNode) -> ChatNode {
        ChatNode(key: node.key, kind: node.kind, businessId: node.businessId,
                 anchorSeq: node.anchorSeq, visibility: .hidden, data: node.data)
    }
}

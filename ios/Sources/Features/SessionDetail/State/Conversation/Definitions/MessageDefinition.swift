/**
 * 一条用户消息 —— 它从不更新，所以身份可以直接取协议里的消息 id。
 *
 * 这是上游那条「单事件业务可以拿事件自身身份当 id」的例外；我们不拿 `seq`，拿 `data.id`，
 * 因为 `seq` 会随水位与分页变化（重连重取同一段时 seq 一样，但换一个窗口就不同）。
 */
import Foundation

struct MessageNodeData: Equatable {
    let text: String
    let time: Double
}

struct MessageDefinition: ConversationNodeDefinition {

    struct State: Equatable {
        let text: String
        let time: Double
    }

    let kind = "message"

    func match(_ event: AssemblyEvent) -> MatchResult? {
        guard event.type == "user/message" else { return nil }
        // 只画人打的字：插件注入的上下文与系统消息不是「某人说的话」。
        guard event.data["source"]?["kind"]?.string == "user" else { return nil }
        guard Self.text(in: event.data["content"]) != nil else { return nil }
        let id = Self.identity(of: event)
        return MatchResult(id: id, role: .start)
    }

    func start(_ context: NodeContext<State>, _ match: ConversationMatch) -> State {
        State(text: Self.text(in: match.event.data["content"]) ?? "", time: match.event.time)
    }

    func update(_ context: NodeContext<State>, _ match: ConversationMatch) -> State {
        context.state ?? start(context, match)
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
            data: .message(MessageNodeData(text: state.text, time: state.time))
        )
    }

    /// 身份：优先协议里的消息 id。
    /// 退路（判据 O1 的唯一例外）：老日志与旧 fixture 没有 `id`，只能退回 `seq` ——
    /// 退回之后这条消息的身份随窗口走，但它从不更新，所以不会引起重建。
    static func identity(of event: AssemblyEvent) -> String {
        if let id = event.data["id"]?.string, !id.isEmpty { return id }
        return "seq:\(event.seq ?? Int(event.order))"
    }

    static func text(in content: JSONValue?) -> String? {
        let parts = (content?.array ?? []).compactMap { block -> String? in
            guard block["type"]?.string == "text" else { return nil }
            return block["text"]?.string
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    static func hidden(_ node: ChatNode) -> ChatNode {
        ChatNode(key: node.key, kind: node.kind, businessId: node.businessId,
                 anchorSeq: node.anchorSeq, visibility: .hidden, data: node.data)
    }
}

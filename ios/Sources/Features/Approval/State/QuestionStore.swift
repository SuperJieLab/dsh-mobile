/**
 * 待答提问的表 + 应答，与 `ApprovalStore` 并列。
 *
 * 为什么是**两个 Store 而不是一个**：行形状完全不同（那边 `toolName`、这边一组题），
 * 合成一个会让每次读取都判空。共用的三件事各自只有一处：分派在 `EventsPendingSink`、
 * 三态在 `AnswerProgress`、`cancel` / `ready` 的语义两边同形。
 *
 * 为什么挂在 **App 级**（与 `ApprovalStore` 一样）：`attach` 是一次性闸，按屏持有会让
 * 「离开详情页再回来」永远收不到卡 —— 流是 App 级的，表也得是。
 */
import Foundation

/// 一次问题应答的出口。可注入：测试要造出「被拒」「没发」这些终局。
protocol QuestionAnswering {
    func answer(eventId: String, answers: [QuestionAnswerItem], answerId: String, clientId: String) async throws
}

/// 生产实现：走 `mobile/questionAnswer`。
@MainActor
struct GatewayQuestionAnswerer: QuestionAnswering {
    let client: RpcClient

    func answer(eventId: String, answers: [QuestionAnswerItem], answerId: String, clientId: String) async throws {
        let _: QuestionAnswerResponse = try await client.perform(
            QuestionAnswerRequest(eventId: eventId, answers: answers, answerId: answerId, clientId: clientId)
        )
        Log.info(Log.Module.session, "question-answer delivered", ["request": eventId])
    }
}

@MainActor
@Observable
final class QuestionStore {

    /// 选择的定义在 `QuestionSelection`（值类型，视图模型也要读它，不该挂在 `@MainActor` 的类上）。
    typealias Selection = QuestionSelection

    private(set) var table = QuestionTable()
    /// 按 `eventId` 的应答进展；没有条目＝还没答过。
    private(set) var states: [String: AnswerProgress] = [:]
    /// 按会话的一句说明（「已投递」/「已经不在了」）。
    private(set) var notices: [String: String] = [:]

    private let answerer: any QuestionAnswering
    @ObservationIgnored private var sink: (any PendingEventSink)?
    @ObservationIgnored private var attached = false

    init(answerer: any QuestionAnswering) {
        self.answerer = answerer
    }

    /// 两处接线一次接完。**只生效一次**：入口不唯一而注册本身不幂等。
    func attach(sink: any PendingEventSink) {
        guard !attached else { return }
        attached = true
        self.sink = sink
        sink.onQuestion { [weak self] payload in self?.receive(payload) }
        sink.onCancel { [weak self] payload in
            guard let eventId = payload["eventId"]?.string, !eventId.isEmpty else {
                Log.warn(Log.Module.session, "dropped a cancel without an eventId")
                return
            }
            self?.cancel(eventId: eventId)
        }
        sink.onReady { [weak self] in self?.clear() }
    }

    /// 宿主通知（`emit`）的转发口 —— **通知不属于任何域**，由持有 sink 的这一个代收一次。
    ///
    /// 分派仍在调用方（`SessionDetailState`）：它才认识「模型 / 命令 / 权限 / 账号」这四个
    /// 消费方，而 Store 只认识自己的表。
    ///
    /// **返回退订**：调用方是 per-screen 的容器，不退订的话每开一次详情页就多一个永久
    /// 听众（`ListenerTable` 只靠 token 删）。
    @discardableResult
    func watchNotifications(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void {
        guard let sink else {
            Log.warn(Log.Module.session, "upstream notifications not watched: the events stream is not attached yet")
            return {}
        }
        return sink.onEmit(handler)
    }

    /// 网关推来的一条提问。
    func receive(_ payload: JSONValue) {
        table.absorb(payload)
        if let sessionId = payload["agentId"]?.string {
            // 新的一张卡来了，上一句说明讲的是别的事。
            notices[sessionId] = nil
        }
        pruneStates()
    }

    func cancel(eventId: String) {
        table.remove(eventId: eventId)
        states[eventId] = nil
    }

    func clear() {
        table.clear()
        states.removeAll()
        notices.removeAll()
    }

    func state(for eventId: String) -> AnswerProgress? { states[eventId] }
    func notice(for sessionId: String) -> String? { notices[sessionId] }
    func pending(in sessionId: String) -> [QuestionTable.Entry] { table.pending(in: sessionId) }

    /// 提交一张卡。守卫只看「有没有状态」—— 在途、未知、被拒的那一张都不再发第二次。
    func answer(_ entry: QuestionTable.Entry, selections: [String: Selection]) async {
        guard states[entry.eventId] == nil else { return }
        // 半张卡不投：网关也会拒，但那要多走一趟网络，且拒的样子与「答案不对」分不开。
        guard QuestionAnswers.isComplete(entry, selections: selections) else { return }
        guard let clientId = sink?.clientId else {
            Log.warn(Log.Module.session,
                     "question-answer not sent: the events stream has no clientId yet",
                     ["request": entry.eventId])
            states[entry.eventId] = .unknown
            pruneStates()
            return
        }
        states[entry.eventId] = .sending
        defer { pruneStates() }
        do {
            try await answerer.answer(
                eventId: entry.eventId,
                answers: QuestionAnswers.payload(entry, selections: selections),
                answerId: UUID().uuidString,
                clientId: clientId
            )
            settle(entry, notice: QuestionText.deliveredNote)
        } catch RpcClientError.refused(let failure) where Self.meansGone(failure.code) {
            // 这条已经不在了（别人答了 / 撤回了 / 换代了）：留着就是一张永远按不动的卡。
            settle(entry, notice: failure.readableDescription)
        } catch RpcClientError.refused(let failure) {
            // 服务端拒了这次投递，提问仍挂着 —— 卡留着并写明原因。
            states[entry.eventId] = .refused(failure.readableDescription)
        } catch {
            states[entry.eventId] = .unknown
        }
    }

    /// 两种「不在了」：别人先答 / 撤回 / 从未提出，与「不是你的这条流」。
    private static func meansGone(_ code: String) -> Bool {
        code == GatewayErrorCode.unknownApproval.rawValue || code == GatewayErrorCode.notOwner.rawValue
    }

    private func settle(_ entry: QuestionTable.Entry, notice: String) {
        table.remove(eventId: entry.eventId)
        guard states[entry.eventId] == .sending else { return }
        states[entry.eventId] = nil
        notices[entry.sessionId] = notice
    }

    /// 表里没有的项不留在状态字典里 —— 否则下一张同身份的卡会因为「已经有状态」而按不动。
    private func pruneStates() {
        let live = Set(table.entries.map(\.eventId))
        states = states.filter { live.contains($0.key) }
    }
}

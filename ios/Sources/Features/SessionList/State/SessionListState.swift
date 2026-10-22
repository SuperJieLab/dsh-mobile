/**
 * 会话列表的状态：取一次列表，把结果落成三种面 —— 有内容 / 失败 / 等待组网。
 *
 * 只回答「取回来是什么」，**不回答「什么时候取」**：触发点登记在 `SessionListView` ——
 * 放进这一层，它就得认识 SwiftUI 的生命周期。例外是事件流的代次：那是「恢复」这个
 * 事实本身（这条流不重放），不是用户手势，所以订阅在 `attach` 里。
 *
 * 三条纪律：
 * - 失败时**不清空**已有列表：能显示多少显示多少，错误挂在上面，文案是服务端的原文。
 * - `notActivated` 是组网就绪前的必经阶段，归入等待面而不是错误面。
 * - **事件是增量，拉取是基线**：整表替换会把在途期间到达的变更抹掉，所以拉取落地时
 *   要把这一批账重放一遍（见 `reload` 与 `apply`）。
 *
 * 单飞：两次 `reload()` 撞在一起时只有一次请求，两次都等它的结果。没有单飞，
 * 「这批账归哪一次请求」就没有答案 —— 而重放的正确性全押在它上面。
 */
import Combine
import Foundation

@MainActor
final class SessionListState: ObservableObject {

    /// 屏幕上要落成的三种面。`failed` 带着要**原样**显示的文案。
    enum Outcome: Equatable {
        case ready
        case failed(String)
        case waitingForMesh
    }

    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var outcome: Outcome = .ready

    /// 取一次列表。收成闭包是为了让「在途期间发生了什么」可被断言 ——
    /// 走真网络时，「两次请求并发」与「一次请求很慢」在测试里长得一样。
    private let fetch: () async throws -> [SessionSummary]
    /// 在途的那一次。单飞的落点，也是这批账的归属。
    private var inflight: Task<[SessionSummary], Error>?
    /// 这一次在途期间到达的变更，按到达顺序 —— 落地时依次重放。
    private var buffered: [SessionListChange] = []
    init(fetch: @escaping () async throws -> [SessionSummary]) {
        self.fetch = fetch
    }

    convenience init(client: GatewayClient) {
        self.init { try await fetchSessions(client) }
    }

    /// 要显示的失败文案；没有失败时是 `nil`。徽标与空态条件都读它 —— 它是三态里失败那一面的
    /// 读法，不是第二份状态。
    var failureText: String? {
        if case .failed(let text) = outcome { return text }
        return nil
    }

    /// 听事件流：每报到一次（含重连拿到相同代次、以及源失效）就重拉一次。
    ///
    /// 这条流不重放，所以「两次报到之间的事件」可能已经丢了 —— 而它在客户端唯一
    /// 可观察的形式就是这一次报到。
    func attach(events: ConnectionEvents) {
        events.onGeneration { [weak self] _ in
            Task { await self?.reload() }
        }
    }

    /// 一条列表增量。立即生效；在途时同时记进这一批账，等落地后重放到响应上。
    func apply(_ change: SessionListChange) {
        sessions = SessionListMerger.apply(change, to: sessions)
        if inflight != nil { buffered.append(change) }
    }

    /// 取一次。服务端给出事实（`blank` / `origin`），**显示哪些**由 `SessionVisibility` 答。
    func reload() async {

        if let running = inflight {
            _ = try? await running.value
            return
        }
        let task = Task { try await fetch() }
        inflight = task
        buffered = []
        isLoading = true
        defer {
            inflight = nil
            buffered = []
            isLoading = false
        }
        do {
            let rows = try await task.value
            // 先摆响应的顺序，再把这批账依次重放 —— 反过来会让事件带来的位置被响应冲掉。
            var merged = rows.filter(SessionVisibility.isVisible)
            for change in buffered { merged = SessionListMerger.apply(change, to: merged) }
            sessions = merged
            outcome = .ready
        } catch {
            // 列表保留（事件带来的变化已经生效），只换失败面。
            if let gatewayError = error as? GatewayClientError, case .notActivated = gatewayError {
                outcome = .waitingForMesh
            } else {
                outcome = .failed(error.localizedDescription)
            }
        }
    }
}

/// 拉会话列表。服务端已按 `updatedAt` 降序排好 —— 协议规定客户端**不必自己排**。
@MainActor
func fetchSessions(_ client: GatewayClient) async throws -> [SessionSummary] {
    let response: ListSessionsResponse = try await client.perform(ListSessionsRequest())
    // clock 采样：服务端时钟与本地收到时刻的一对。两端 offset 由这一对估出来，
    // 才能修正跨机的 t3 段与端到端 —— 直接相减会把这个 offset 算进延迟里。
    //
    // 采样点在这里而不是更上层：`serverTime` 只出现在这个回包里，而「收到的时刻」
    // 越贴近解码越准。挪动这个函数就等于挪动采样点。
    if let serverTime = response.serverTime {
        Log.perf(Log.Module.gateway, PerfRecord(
            seg: .clock, t: PerfRecord.nowMs(),
            fields: ["serverTime": .number(serverTime)]
        ))
    }
    return response.sessions ?? []
}

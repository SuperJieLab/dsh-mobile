/**
 * 会话列表的状态：取一次，把结果落成三种面 —— 有内容 / 前置不满足 / 真失败。
 *
 * 只回答「取回来是什么」，**不回答「什么时候取」**：触发点归视图。唯一的例外是事件流的代次
 * （那是「恢复」这个事实本身）。失败不清空已有列表；前置不满足是 `blocked` 而非 `failed`。
 */
import Foundation

@MainActor
@Observable
final class SessionListState {

    /// `blocked` 与 `failed` 的分界不在严重程度，在**谁的问题**：前者是这台机器还差一步
    /// 配置（用户去设置里做），后者是这次请求坏了。两者的文案都是服务端原文。
    enum Outcome: Equatable {
        case ready
        case blocked(String)
        case failed(String)
    }

    private(set) var sessions: [SessionSummary] = []
    private(set) var isLoading = false
    private(set) var outcome: Outcome = .ready

    /// 取一次列表。收成闭包是为了让「在途期间发生了什么」可被断言 ——
    /// 走真网络时，「两次请求并发」与「一次请求很慢」在测试里长得一样。
    private let fetch: () async throws -> [SessionSummary]
    /// 在途的那一次。单飞的落点，也是这批账的归属。
    private var inflight: Task<[SessionSummary], Error>?
    /// 这一次在途期间到达的变更，按到达顺序。进 `reload` 时必然为空 —— `apply` 只在
    /// `inflight != nil` 时入账，而它只在 `reload` 体内非 nil。
    private var buffered: [SessionListChange] = []
    /// 是否已经听过事件流（`attach` 幂等）。
    private var attached = false
    init(fetch: @escaping () async throws -> [SessionSummary]) {
        self.fetch = fetch
    }

    convenience init(client: RpcClient) {
        self.init { try await fetchSessions(client) }
    }

    /// 失败面的读法，不是第二份状态。
    var failureText: String? {
        if case .failed(let text) = outcome { return text }
        return nil
    }

    /// 前置那一面的读法；视图据此决定画中性提示还是红条。
    var blockedReason: String? {
        if case .blocked(let text) = outcome { return text }
        return nil
    }


    /// 听事件流。这条流不重放，所以「两次报到之间的事件」可能已经丢了 —— 报到这里是它在
    /// 客户端唯一可观察的形式。幂等：视图重复出现时不该注册第二个听众。
    func attach(events: EventStream) {
        guard !attached else { return }
        attached = true
        // 两件都接：逐条的增量（改一行），与每一次报到（重拉基线）。少接一条的症状是
        // 「列表不自己动」或「断线之后再也不对齐」—— 都不编译失败。
        // 增量的解释在这里：挖 `change`、解形状、认不出丢弃。
        events.onCargo("session-list") { [weak self] payload in
            guard let change = payload["change"].flatMap(SessionListChange.decode) else {
                Log.warn(Log.Module.session,
                         "dropped a session-list change this build does not know")
                return
            }
            self?.apply(change)
        }
        events.onGeneration { [weak self] _ in
            Task { await self?.reload() }
        }
    }

    /// 一条列表增量。立即生效；在途时同时记进这一批账，等落地后重放到响应上。
    ///
    /// **可见性两条路都要筛**：事件推来的行若不过 `SessionVisibility`，`blank`（在 Mac 上
    /// 刚点新建、还没说话）与 `subagent` 会当场出现，下拉之后又消失。
    func apply(_ change: SessionListChange) {
        sessions = visible(SessionListMerger.apply(change, to: sessions))
        if inflight != nil { buffered.append(change) }
    }

    private func visible(_ rows: [SessionSummary]) -> [SessionSummary] {
        rows.filter(SessionVisibility.isVisible)
    }

    /// 服务端给出事实（`blank` / `origin`），**显示哪些**由 `SessionVisibility` 答。
    func reload() async {

        if let running = inflight {
            _ = try? await running.value
            return
        }
        let task = Task { try await fetch() }
        inflight = task
        isLoading = true
        defer {
            inflight = nil
            buffered = []
            isLoading = false
        }
        do {
            let rows = try await task.value
            // 先摆响应的顺序，再把这批账依次重放 —— 反过来会让事件带来的位置被响应冲掉。
            var merged = visible(rows)
            for change in buffered { merged = SessionListMerger.apply(change, to: merged) }
            // 重放会把事件推来的行加回去，所以落地之后再筛一次 —— 只筛一次的话，在途
            // 期间到达的 blank / subagent 会从这里漏进列表。
            sessions = visible(merged)
            outcome = .ready
        } catch {
            // 列表保留（事件带来的变化已经生效），只换失败面。
            //
            // 分类只看错误的类型，**不去推算「现在缺什么」**：`FailureText` 已经把两种前置
            // 说成了两句不同的话（组网未就绪 / 还没有配对），端上再猜一遍就会有两个说法。
            if let gatewayError = error as? RpcClientError, Self.isPrerequisite(gatewayError) {
                outcome = .blocked(error.localizedDescription)
            } else {
                outcome = .failed(error.localizedDescription)
            }
        }
    }
}

extension SessionListState {
    /// 这个错误是不是「还差一步配置」而不是「这次请求坏了」。
    ///
    /// 只有两个取值在此列：隧道产物还没有、没有可用身份。其余（传输失败、状态码、协议
    /// 拒绝）都是这一次请求的事 —— 把它们说成配置问题，用户会去改一件没坏的东西。
    static func isPrerequisite(_ error: RpcClientError) -> Bool {
        switch error {
        case .notActivated, .unauthenticated: return true
        default: return false
        }
    }
}

/// 拉会话列表。服务端已按 `updatedAt` 降序排好 —— 协议规定客户端**不必自己排**。
@MainActor
func fetchSessions(_ client: RpcClient) async throws -> [SessionSummary] {
    let response: ListSessionsResponse = try await client.perform(ListSessionsRequest())
    // clock 采样：服务端时钟与本地收到时刻的一对。两端 offset 由这一对估出来，
    // 才能修正跨机的 t3 段与端到端 —— 直接相减会把这个 offset 算进延迟里。
    // 采样点在这里而不是更上层：`serverTime` 只出现在这个回包里，而「收到的时刻」
    if let serverTime = response.serverTime {
        Log.perf(Log.Module.gateway, PerfRecord(
            seg: .clock, t: PerfRecord.nowMs(),
            fields: ["serverTime": .number(serverTime)]
        ))
    }
    return response.sessions ?? []
}

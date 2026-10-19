/**
 * 会话列表的状态：取一次会话列表，把结果落成三种面 —— 有内容 / 失败 / 等待组网。
 *
 * 只回答「取回来是什么」，**不回答「什么时候取」**：触发点登记在 `SessionListView` 里
 * （它为什么留在那儿，见该文件头）。触发点搬进来的话，这一层就得认识 SwiftUI 的生命周期。
 *
 * 两条纪律沿用既有语义：
 * - 失败时**不清空**已有列表：能显示多少显示多少，错误挂在上面，文案是服务端的原文。
 * - `notActivated` 是组网就绪前的必然阶段，归入等待面而不是错误面（R5 修正 4②）。
 *
 * 可重入：两次 `reload()` 并发时后完成者覆盖结果，没有单飞守卫 —— 这是改动前的行为，
 * 本期不改（R16 期1 决定 A4，代价登记在 `ISSUES` C26）。
 *
 * `State` 下不 import SwiftUI —— 判据在 `tests/LayeringTests.swift`。
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

    private let client: GatewayClient

    init(client: GatewayClient) {
        self.client = client
    }

    /// 要显示的失败文案；没有失败时是 `nil`。徽标与空态条件都读它 —— 它是三态里失败那一面的
    /// 读法，不是第二份状态。
    var failureText: String? {
        if case .failed(let text) = outcome { return text }
        return nil
    }

    /// 取一次。服务端给出事实（`blank` / `origin`），**显示哪些**由 `SessionVisibility` 答。
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await client.listSessions().filter(SessionVisibility.isVisible)
            outcome = .ready
        } catch {
            if let gatewayError = error as? GatewayClientError, case .notActivated = gatewayError {
                outcome = .waitingForMesh
            } else {
                outcome = .failed(error.localizedDescription)
            }
        }
    }
}

/**
 * 导航栈里的一个目的地。全应用只有这一张出口清单：屏只发 `NavigationLink(value:)`，
 * 装配在组合根的 `.navigationDestination(for:)` 里一处完成。
 *
 * 加一屏 = 这里加一支 + 组合根加一条匹配。不叫 `Route`：`MeshStore.Route` 已是隧道的产物。
 */
import Foundation

enum Destination: Hashable {
    /// 带整份 `SessionSummary` 而不只是 id：那一屏首帧就要标题与状态，而列表手上就有 ——
    /// 不给它一个「先空着、再查一遍」的阶段。
    case session(SessionSummary)
    case settings
    /// 地址、接入密钥、节点五态。
    case mesh
    case pairing
}

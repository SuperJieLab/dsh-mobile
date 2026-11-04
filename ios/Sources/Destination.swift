/**
 * 导航栈里的一个目的地。全应用只有这一张出口清单：屏只发 `NavigationLink(value:)`，
 * 装配在组合根的 `.navigationDestination(for:)` 里一处完成。
 *
 * 加一屏 = 这里加一支 + 组合根加一条匹配。不叫 `Route`：`MeshStore.Route` 已是隧道的产物。
 */
import Foundation

enum Destination: Hashable {
    /// 会话详情。带的两格是那一屏真正读的东西：`sessionId` 与 `title`（标题可缺 ——
    /// 刚建的空会话就没有）。**不带整份摘要**：详情屏一个别的字段都不读，而新建出来的
    /// 空会话凑不出一份完整摘要（也没有必要凑）。
    case session(sessionId: String, title: String?)
    case settings
    /// 地址、接入密钥、节点五态。
    case mesh
    case pairing
    /// 写操作的历史。审计不是日志：这里只列「谁改了什么」，不含过程。
    case audit
}

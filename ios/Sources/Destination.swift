/**
 * 导航栈里的一个目的地。
 *
 * **全应用只有一张出口清单，它在这里。** 屏只发 `NavigationLink(value:)`，装配写在组合根的
 * `.navigationDestination(for:)` 里 —— 那样依赖不必逐层往下传：列表与设置都不需要持有
 * 下一屏的依赖，它们只需要发一个值。
 *
 * 住在 `Sources/` 顶层而不是 `Features/` 下：它不属于任何一屏，也不是一屏。它和组合根
 * （`DshMobileApp.swift`）同层，因为「根注册什么、屏发什么」是同一份契约的两半 ——
 * 分开放，读的人要在两个目录之间对。
 *
 * 四支各自对应一个可以推入的屏。加一屏 = 加一支 + 在根加一条匹配，两处都在同一份清单上。
 *
 * 名字取 SwiftUI 的参数名（`navigationDestination(for:destination:)` 里那个 destination），
 * 而不叫 `Route`：`MeshStore.Route` 已经是「隧道的产物」（一条传输加一个地址），
 * 同名的两个类型会让读的人反复确认「这是哪个 Route」。
 *
 * **为什么连设置也走值**：混着写（详情走值、设置走视图）需要解释「什么时候用哪种」，而
 * 那种解释每个新屏都要重讲一遍。一条规则说得完，就从第一天用一条。
 */
import Foundation

enum Destination: Hashable {
    /// 一个会话的详情。带 `SessionSummary` 而不只是 id：那一屏的首帧要用标题与状态，
    /// 而列表手上就有 —— 不给它一个「先空着、再查一遍」的阶段。
    case session(SessionSummary)
    /// 设置：组网与身份两个入口都在里面。
    case settings
    /// 组网配置（地址、接入密钥、节点五态）。从设置进入。
    case mesh
    /// 配对（6 位码 + 解除）。从设置进入。
    case pairing
}

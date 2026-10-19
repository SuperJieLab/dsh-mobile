/**
 * 到网关对端的连接方式：直连还是中继。
 *
 * 三方共用且没有主次 —— 组网节点产出它、连接域的窄面接口用它做返回类型、呈现层按它选
 * 显示档位。它不属于其中任何一方，所以住在 `Core/` 顶层，与 `Log` / `PerfRecord` /
 * `RefreshGate` 同一类：跨域共用的小值。
 *
 * 加第三个取值时，`ConnectionBadge.look` 的 switch 会编译失败 —— 那里逐个 case 列举，
 * 不用 `default`，所以新取值不会被静默归到某一支。
 */
import Foundation

enum CarrierPath: Equatable {
    case direct
    case relay
}

/**
 * 到网关对端的连接方式：直连还是中继。
 *
 * 三方共用且没有主次（组网节点产出、连接域窄面用、呈现层按它选档位），所以住 `Core/` 顶层。
 * 加第三个取值时 `ConnectionBadge.look` 的 switch 会编译失败；对用户的说法只有一份。
 */
import Foundation

enum CarrierPath: Equatable {
    case direct
    case relay
}

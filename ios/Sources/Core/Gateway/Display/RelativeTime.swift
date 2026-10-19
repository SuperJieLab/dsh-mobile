/**
 * 列表与详情的相对时间显示 —— 一种显示格式，不是协议规则。
 *
 * 只改说法（locale、unitsStyle）时不需要动合约；协议里的时刻表示（epoch 毫秒）仍在
 * `Contract/GatewayProtocol.swift` 的 `epochMilliseconds`。
 *
 * 消费者：`SessionListView` 的会话行。
 */
import Foundation

/// 列表与详情里统一用的相对时间显示。
func relativeTime(_ value: Double) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: epochMilliseconds(value), relativeTo: Date())
}

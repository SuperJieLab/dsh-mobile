/**
 * 列表与详情的相对时间显示 —— 一种显示格式，不是协议规则。
 *
 * 只改说法（locale、unitsStyle）时不需要动线上形状；协议里的时刻表示仍在 `RpcMessages`。
 * 只有会话列表的会话行与连接详情读它。
 */
import Foundation

/// 列表与详情里统一用的相对时间显示。
func relativeTime(_ value: Double) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: epochMilliseconds(value), relativeTo: Date())
}

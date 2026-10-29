/**
 * 页脚那句「N 个会话 · 地址」里地址的那一半 —— 一种显示格式，不是协议规则。
 *
 * 调用方是会话列表的页脚：它读不到隧道产物，渲染层也就不可能在别处顺手取它。
 */
import Foundation

/// 网关地址的显示形式。`nil` = 组网还没激活，端点尚不存在。
func gatewayAddressLine(_ url: URL?) -> String {
    guard let url else { return "未激活" }
    return url.absoluteString
}

/**
 * 页脚那句「N 个会话 · 地址」里地址的那一半 —— 一种显示格式，不是协议规则。
 *
 * 调用方是会话列表的页脚：它只拿到这一行字，读不到隧道产物 —— 渲染层不认识通信域，
 * 也就不可能在别处顺手取它。判据是一句可扫的话：列表相关文件里不出现组网类型。
 *
 * 只有会话列表的页脚读它 —— 详情屏的地址在连接详情那张 sheet 里，说的是另一件事
 * （相位、路径、节点状态），不是同一句话。
 */
import Foundation

/// 网关地址的显示形式。`nil` = 组网还没激活，端点尚不存在。
func gatewayAddressLine(_ url: URL?) -> String {
    guard let url else { return "未激活" }
    return url.absoluteString
}

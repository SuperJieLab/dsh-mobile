/**
 * 权限预设的载荷。与链路无关：一个可选项，以及读回来的那一份视图。
 */
import Foundation

/// 一个可选的权限预设。
///
/// `value` 是预设键（宿主配置里的名字，或集成注册的 `auto`）；`name` 是给人看的标签，
/// 宿主没配时就是键本身。**客户端只在 `name == value` 时用自己的中文表**，其余原样显示 ——
/// 宿主给了自定义名就让位，否则用户会在两处看到两个名字。
struct PermissionOption: Decodable, Equatable {
    let value: String
    let name: String
    /// 一句话说明它意味着什么；宿主没配就没有这个字段。
    var description: String? = nil
}

/// 读 op 回来的那一份：此刻能选什么、现在是什么。
///
/// 两格都可以缺席，含义不同：
/// - `options` 缺席 = 这个装配没有权限服务（界面据此**不画**那一格）；
///   `options` 是空数组 = 服务在、但一项都没配。
/// - `current` 缺席 = 宿主不知道（会话不在、或投影没注册）—— 不是「默认档」。
struct PermissionView: Equatable {
    var current: String? = nil
    var options: [PermissionOption]? = nil
}

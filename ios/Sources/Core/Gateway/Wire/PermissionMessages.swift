/**
 * 权限预设的载荷。与链路无关：一个可选项，以及目录那一份。
 *
 * **当前档不在这里** —— 它住在 `permissions` 投影里（`{currentValue}`），由
 * `session/control` 推过来。两处各一份就会出现「目录新、当前值旧」而没人分得清。
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

/// 目录 —— 与上游 `PermissionCatalog` 同形。
///
/// 三格都声明成可选只为一件事：**服务缺席时三键一起缺席**（界面据此不画那一格）。
/// 服务在时的三键是必填，缺席会被当成「这个装配没有权限服务」。
struct PermissionCatalog: Equatable {
    var options: [PermissionOption]? = nil
    /// 装配声明的全部（不看当前集成）。
    var defaultOptions: [PermissionOption]? = nil
    /// **配置的默认档**，不是当前档；只在重拉期间兜底显示。
    var defaultPreset: String? = nil
}

/**
 * 命令的载荷。与链路无关。
 *
 * 形状与上游 `CommandDescriptor` 同形 —— 网关把宿主的描述符原样转发，所以这里少一格、
 * 改一个名，手机上的 `/` 菜单就会与 Web UI 的菜单长得不一样。
 */
import Foundation

/// 宿主的一条命令的参数提示 —— 与上游 `CommandInputDescriptor` 同形。
struct CommandInput: Decodable, Equatable {
    /// 自由输入前的占位提示（如 `<preset>`）。
    let hint: String
    /// 它能不能带附件。缺席或 `false` = 带附件的调用会被拒（本期不接附件）。
    var attachments: Bool? = nil
}

/// 宿主的一条命令。名字与说明按宿主原样显示；`input.hint` 有值时当参数占位提示。
struct CommandDescriptor: Decodable, Equatable {
    /// 插件持有的稳定身份；不按身份做行为的命令没有这一格。
    var definitionId: String? = nil
    let name: String
    let description: String
    /// 缺席 = 这条命令不带自由参数。
    var input: CommandInput? = nil
}

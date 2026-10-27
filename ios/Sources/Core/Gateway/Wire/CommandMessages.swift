/**
 * 命令的载荷。与链路无关。
 */
import Foundation

/// 宿主的一条命令。名字与说明按宿主原样显示；`inputHint` 有值时当参数占位提示。
struct CommandInfo: Decodable, Equatable {
    let name: String
    let description: String
    var inputHint: String? = nil
}

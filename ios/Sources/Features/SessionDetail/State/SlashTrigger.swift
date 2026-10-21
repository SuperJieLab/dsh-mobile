/**
 * 斜杠触发与命令目录 —— 「这行字在敲命令吗」与「有哪些命令可选」两条判定。
 *
 * 都是纯值：不碰网络、不碰 SwiftUI。视图只把它们的结论画出来。
 *
 * 判定只回答两件事：草稿当前算不算「正在敲命令」（以及查询串是什么），
 * 以及选中一条之后草稿该变成什么。**不解析命令行** —— 那是宿主的语法，
 * 客户端拼错就是第二份实现。
 */
import Foundation

/// 草稿此刻与命令面板的关系。
enum SlashTrigger: Equatable {

    /// 不在敲命令（面板收起）。
    case inactive

    /// 在敲命令；`query` 是 `/` 之后、空白之前的那一段（可能为空 = 还没开始打字）。
    case querying(String)

    /// 从草稿判断是否在敲命令。
    ///
    /// 规则：**整段以 `/` 开头，且第一个 `/` 之后还没有空白**。空白一出现就说明用户已经
    /// 进到参数里，面板该收起（再弹着候选会挡住他自己写参数）。
    ///
    /// 只认「整段以 / 开头」而不是「任意位置有 /」：手机上发一条含 `/` 的普通消息（路径、
    /// 分数）是常事，把那种也算命令，等于把用户的正常消息变成一次执行。
    static func of(draft: String) -> SlashTrigger {
        guard draft.hasPrefix("/") else { return .inactive }
        let rest = draft.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace }) else { return .inactive }
        return .querying(String(rest))
    }

    /// 选中一条命令之后草稿该变成什么。
    ///
    /// 一律补一个尾空格：命令名之后的那个分隔符是宿主语法的一部分，补上它用户才能直接
    /// 接着写参数。无参数的命令多一个空格无害（宿主的 `rawInput` 会 trim）。
    static func insert(name: String) -> String {
        "/\(name) "
    }
}

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
    /// 接着写参数。无参数的命令因此会拿到一段只含空格的 `rawInput` —— 宿主原样取 `/`
    /// 之后的那段、不替调用方裁，本端也不替它裁。
    static func insert(name: String) -> String {
        "/\(name) "
    }
}

/// 一行字该走哪条路 —— **安全面上最有后果的一条判定**，所以它在状态层，不在视图里。
///
/// 走错方向的后果不对称：该发给模型的话走成命令，会被宿主当命令解析（可能真的执行了什么）；
/// 该执行的命令走成消息，会变成一句对模型说的话。
enum SlashDispatch: Equatable {
    /// 交给命令通道，原样一整行。
    case command(String)
    /// 发给模型。
    case prompt(String)
}

extension SlashTrigger {

    /// 分流：**归一化之后**整段以 `/` 开头就交给命令通道，否则发给模型。
    ///
    /// 入参必须是归一化后的文本（`PromptDraft.normalized`）—— 面板那侧（`of(draft:)`）读的
    /// 是同一份归一化结果。两边同源是硬要求：各读一份原始草稿时，`" /permission"`（前导空格）
    /// 会让面板判「不在敲命令」而发送判「是命令」—— 用户看不到候选，却执行了一条命令。
    ///
    /// 这里只回答「走哪条路」，不切名字与参数：那是宿主的语法，客户端切一遍就是第二份实现。
    static func dispatch(of normalizedText: String) -> SlashDispatch {
        normalizedText.hasPrefix("/") ? .command(normalizedText) : .prompt(normalizedText)
    }
}

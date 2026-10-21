/**
 * 命令面板的说法 —— 拿不到列表、没有匹配、空列表各自那一句。
 *
 * 变化原因与 `State/CommandDirectory.swift` 不同：句子随产品决定变，三面的映射随协议变。
 * 判定不引用这里的句子 —— 编排文件里出现用户可见的中文字面量时
 * `LayeringTests.testStateHasNoUserFacingStrings` 会红。
 */
import Foundation

extension CommandDirectory.Cause {

    /// 面板里那一句。**服务端原文优先**：协议码不认识时 `readableDescription` 原样给 message。
    var line: String {
        switch self {
        case .refused(let failure):
            return "命令列表没取到：\(failure.readableDescription)"
        case .offline:
            return "命令列表没取到 —— 没连上网关。"
        }
    }
}

extension CommandDirectory {

    /// 列表拉回来了但一条都没有 —— 与「没加载出来」在屏幕上会看起来一样。
    static let emptyNote = "这个会话没有可用的命令。"

    /// 过滤之后没有匹配。
    static let noMatchNote = "没有匹配的命令。"
}

extension CommandInfo {

    /// 候选行上「这条命令怎么用」：名字，以及宿主声明的参数占位。
    ///
    /// 占位提示就来自宿主的 `input.hint` —— 客户端不知道任何一条命令该带什么参数，
    /// 也不该知道（那样插件换个写法，提示就骗人）。`hint` 缺席或为空时只给名字：
    /// 补一个凭空的 `<参数>` 会把「不用参数」说成「要参数」。
    var invocation: String {
        guard let inputHint, !inputHint.isEmpty else { return "/\(name)" }
        return "/\(name) \(inputHint)"
    }
}

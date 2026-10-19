/**
 * 模型目录那三面里的说法 —— 失败那两句、空目录那一句。
 *
 * 变化原因与 `State/ModelCatalogState.swift` 不同：句子随产品决定变，三面的映射随协议变。
 * 判定不引用这里的句子 —— 编排文件里出现用户可见的中文字面量时
 * `LayeringTests.testStateHasNoUserFacingStrings` 会红。
 */
import Foundation

extension ModelCatalogState.Cause {

    /// 菜单里那一句。**服务端原文优先**：协议码不认识时 `readableDescription` 原样给 message；
    /// 认识的码给中文解释 —— 与状态行、审批卡共用同一份解释，三处不会各说一套。
    var line: String {
        switch self {
        case .refused(let failure):
            return "目录没取到：\(failure.readableDescription)"
        case .offline:
            return "目录没取到 —— 没连上网关。"
        }
    }
}

extension ModelCatalog {

    /// 目录拉回来了，但一个模型都没有 —— 空菜单与「没加载出来」在屏幕上会看起来一样。
    /// 与这一份目录的内容无关，所以是 `static`：写成实例属性会让人以为它读 `groups`。
    static let emptyNote = "网关没有可用的模型。"
}

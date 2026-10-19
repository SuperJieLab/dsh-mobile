/**
 * 模型目录那三面里的说法 —— 失败那两句、空目录那一句。
 *
 * 与 `State/ModelCatalogState.swift` 分家的理由：句子随产品决定变，三面的映射随协议变。
 * 判定不引用这里（`LayeringTests.testStateDoesNotReferenceItsDisplay` 守着方向）。
 *
 * 消费者：`ModelPickerView`。
 */
import Foundation

extension ModelCatalogState.Cause {

    /// 菜单里那一句。**服务端原文优先**：协议码不认识时 `readableDescription` 原样给 message；
    /// 认识的码给中文解释（期1 定的口径，与状态行、审批卡共用同一份）。
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
    var emptyNote: String {
        "网关没有可用的模型。"
    }
}

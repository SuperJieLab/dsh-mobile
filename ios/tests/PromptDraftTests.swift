/**
 * 发送规则的断言：「什么算有内容」与「发出去的文本长什么样」。
 *
 * 这一条原先在视图的 `disabled` 表达式与 `SessionSync.sendPrompt`
 * 的 guard 里各写一遍（两处都 trim），漂移后的症状是「按钮亮了但点了没反应」。
 *
 * 现在两处读同一个 `PromptDraft.normalized`，且它返回**要发的文本**而不是布尔 ——
 * 「判空」与「取值」因此不可能分家。
 *
 */
import Foundation
import XCTest

@testable import DshMobile

final class PromptDraftTests: XCTestCase {

    /// 只有空白（含换行、制表）就是没有内容。
    func testBlankIsNil() {
        XCTAssertNil(PromptDraft.normalized(""), "空串没有内容")
        XCTAssertNil(PromptDraft.normalized("   "), "空格没有内容")
        XCTAssertNil(PromptDraft.normalized(" \n\t "), "空白与换行、制表都没有内容")
    }

    /// 首尾削掉，中间的换行原样保留。
    func testTrimsEndsOnly() {
        XCTAssertEqual(PromptDraft.normalized(" 你好 "), "你好", "首尾空白削掉")
        XCTAssertEqual(PromptDraft.normalized("\n你好\n"), "你好", "首尾换行削掉")
        XCTAssertEqual(PromptDraft.normalized("a\nb"), "a\nb", "正文中间的换行是排版，不削")
        XCTAssertEqual(PromptDraft.normalized("a\n\nb "), "a\n\nb", "只削首尾，空行保留")
    }
}

/**
 * 「这条输入算不算有内容」的唯一判定 —— 发送按钮的置灰与 `sendPrompt` 的入口读同一份。
 *
 * 返回的是**要发出去的文本**，不是布尔：只给布尔的话，编排还得再 trim 一次，trim 就有了两份
 * （一处判空、一处取值），迟早有一处漏改。返回文本让两件事同源。
 *
 * 纯判定：不 import SwiftUI、不读全局状态（判据在 `tests/PromptDraftTests.swift`）。
 *
 * 消费者：`ComposerState`（发送按钮的 `canSubmit` 与提交时的取值）。
 */
import Foundation

enum PromptDraft {

    /// 削掉首尾空白与换行后的文本；什么都不剩就是 `nil`。
    ///
    /// **只削首尾**：正文中间的换行是用户的排版，不碰。
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/**
 * 过程折叠头上那句话 —— 只写非零的计数，都是 0 而确实有过程时用兜底文案。
 *
 * 用户可见的句子归 `Display/`：同一批计数换个屏就换说法，放在 State 里等于把文案钉死在组装结果上。
 */
import Foundation

enum ProcessText {

    static func summary(_ entries: [ProcessEntry]) -> String? {
        var toolCalls = 0
        var midMessages = 0
        var hasThinking = false
        for entry in entries {
            switch entry {
            case .tool: toolCalls += 1
            case .text: midMessages += 1
            case .thinking: hasThinking = true
            }
        }

        var parts: [String] = []
        if toolCalls > 0 { parts.append("\(toolCalls) 次工具调用") }
        if midMessages > 0 { parts.append("\(midMessages) 条消息") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return hasThinking ? "已思考" : nil
    }
}

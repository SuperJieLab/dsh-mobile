/**
 * 会话列表的可见性规则：给定一行摘要，回答「这一行显示不显示」。
 *
 * 规则与上游可见性同源：`blank` 是还没有任何 turn 的候补新会话，点进去只有策略事件；
 * `origin == "subagent"` 是别的会话的子会话，不是独立对话。网关另有一条「没有 cwd 的会话
 * 不列」，在适配器里 —— 与这里不是同一处判断，不要并过来。
 *
 * 纯函数、无状态、不 import SwiftUI：这样它能在没有界面、也没有网关的条件下被断言
 * （`tests/SessionVisibilityTests.swift` 四条）。
 */
import Foundation

enum SessionVisibility {
    /// 这一行该显示吗。只拦 `blank` 与 `subagent` 两个值，其余一律显示。
    static func isVisible(_ session: SessionSummary) -> Bool {
        if session.blank { return false }
        return session.origin != "subagent"
    }
}

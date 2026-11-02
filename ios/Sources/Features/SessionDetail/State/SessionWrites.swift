/**
 * 把用户的一个动作交给宿主：发一条话、装一次模型选择。
 *
 * 共同点是**回包只表示受理**，真正的结果从订阅流回来。两条的失败说法不同，所以不合成一个入口。
 *
 * 两条成功时都留一行：它们「成功了但后面没动静」的样子与「根本没发出去」在界面上分不开，
 * 而 `promptId` 是唯一能与流里那条回答对上的号。
 */
import Foundation

/// 下发一条指令（发消息进会话）。`ok` 意味着**已受理**——回答本身从流里来。
@MainActor
func promptSession(
    _ client: RpcClient,
    sessionId: String,
    text: String,
    promptId: String
) async throws {
    let _: SessionPromptResponse = try await client.perform(
        SessionPromptRequest(sessionId: sessionId, text: text, promptId: promptId)
    )
    // 正文长度而不是正文：内容属于会话，日志不该成为它的第二份副本。
    Log.info(Log.Module.session,
             "session-prompt \(sessionId) accepted (prompt=\(promptId), \(text.count) chars)")
}

/// 安装一次会话级选择。`ok` = **已安装给下一轮**，不是「已生效」——
/// 生效的证据是流里的 `model/selection` 与随后的 `request/header`。
/// 返回服务端归一化后的选择：本地即时显示读它，而不是把发出去的那份当答案。
@MainActor
func installModelSelection(
    _ client: RpcClient,
    sessionId: String,
    selection: ModelSelection
) async throws -> ModelSelection {
    let response: ModelSelectResponse = try await client.perform(
        ModelSelectRequest(
            sessionId: sessionId,
            provider: selection.provider,
            model: selection.model,
            reasoningEffort: selection.reasoningEffort
        )
    )
    guard let selected = response.selected else {
        throw RpcClientError.malformedResponse(detail: "selected")
    }
    // 记**服务端归一化之后**的那一份：用户点的是 A，宿主可能答回 B，日志要能看出这个替换。
    Log.info(Log.Module.session,
             "model-select \(sessionId) → \(selected.provider)/\(selected.model)")
    return selected
}

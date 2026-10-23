/**
 * 把用户的一个动作交给宿主：发一条话、装一次模型选择。
 *
 * 共同点是**回包只表示受理**，真正的结果都从订阅流回来 —— 话的回答来自 `assistant/message`，
 * 选择的生效来自 `model/selection` 与随后的 `request/header`。这层因此不读回包的语义，
 * 只把「问了什么」拼对、把「受理了没有」交给调用方。
 *
 * 两条的失败说法不同（状态行上一个是「指令没能送达」、一个是「选择没能装上」），
 * 所以不合成一个入口。
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
}

/// 安装一次会话级选择。`ok` = **已安装给下一轮**，不是「已生效」——
/// 生效的证据是流里的 `model/selection` 与随后的 `request/header`。
///
/// 返回服务端归一化后的选择：本地即时显示读它，而不是把发出去的那份当答案 ——
/// 上游可能补上默认档或改掉名字，所以不要把发出去的那份当成答案。
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
    return selected
}

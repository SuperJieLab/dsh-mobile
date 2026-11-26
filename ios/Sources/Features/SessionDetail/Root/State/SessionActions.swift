/**
 * 用户的一次动作落到宿主：发一条话、发一行命令、装一次模型选择。
 *
 * **回包只表示受理**，结果从订阅流回来。三种失败的补救不同（草稿留不留、要不要等），
 * 所以不合成一个入口；而它们报的是同一条状态行，所以共享 `SessionStatus`。
 * 「这一行该走哪条路」不在这里 —— 那是 `SessionSync` 的判定（它还要顺手记乐观行）。
 *
 * 它不碰镜像、不碰流：读侧的东西一个都不认识 —— 这是它与 `SessionSync` 分开的理由。
 * 变化触发源也不同：这里随「产品动作的语义」变（发消息带什么、命令怎么走），
 * 读侧随「窗口与快照的协议」变。
 */
import Foundation

@MainActor
final class SessionActions {

    private let client: RpcClient
    private let sessionId: String
    private let status: SessionStatus
    private let models: SessionModelMirror

    init(client: RpcClient, sessionId: String, status: SessionStatus, models: SessionModelMirror) {
        self.client = client
        self.sessionId = sessionId
        self.status = status
        self.models = models
    }

    /// 安装一次会话级选择：本地先记代号，回包对号落地。
    func selectModel(_ selection: ModelSelection) async {
        let generation = models.beginSelect()
        do {
            let selected = try await installModelSelection(
                client, sessionId: sessionId, selection: selection
            )
            models.settle(generation: generation, selected: selected)
        } catch {
            status.set(.failed(step: .selecting, cause: .thrown(error)))
        }
    }

    /// 下发一条话；`requestId` 由调用方铸（乐观行与请求共用同一个号）。
    func sendPrompt(_ text: String, requestId: String, mode: SessionPromptRequest.Mode) async -> Bool {
        // 与发送按钮的置灰读同一份判定 —— 「判空」与「取值」同源。
        guard let trimmed = PromptDraft.normalized(text) else { return false }
        do {
            try await promptSession(
                client, sessionId: sessionId, text: trimmed, requestId: requestId, mode: mode
            )
            return true
        } catch {
            // 失败要留一行：屏幕上的状态行只说「发送失败」，归因得回到日志。
            Log.warn(Log.Module.session, "prompt not accepted",
                     ["session": sessionId, "key": requestId, "mode": mode.rawValue,
                      "error": String(describing: error)])
            status.set(.failed(step: .sending, cause: .thrown(error)))
            return false
        }
    }

    /// 执行一整行命令；回包 ok = 已受理，结果从订阅流来。
    func executeCommand(_ line: String) async -> Bool {
        do {
            try await runCommand(client, agentId: sessionId, line: line)
            return true
        } catch {
            status.set(.failed(step: .executing, cause: .thrown(error)))
            return false
        }
    }
}

/**
 * 用户的一次动作落到宿主：发一条话、发一行命令、装一次模型选择。
 *
 * **回包只表示受理**，结果从订阅流回来。三种失败的补救不同（草稿留不留、要不要等），
 * 所以不合成一个入口；而它们报的是同一条状态行，所以共享 `SessionStatus`。
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

    /// 下发一条指令；返回「是否已受理」，调用方据此决定清不清草稿。
    func deliver(_ dispatch: SlashDispatch) async -> Bool {
        switch dispatch {
        case .command(let line): return await executeCommand(line)
        case .prompt(let text): return await sendPrompt(text)
        }
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

    private func sendPrompt(_ text: String) async -> Bool {
        // 与发送按钮的置灰读同一份判定 —— 「判空」与「取值」同源。
        guard let trimmed = PromptDraft.normalized(text) else { return false }
        do {
            try await promptSession(
                client, sessionId: sessionId, text: trimmed, promptId: UUID().uuidString
            )
            return true
        } catch {
            status.set(.failed(step: .sending, cause: .thrown(error)))
            return false
        }
    }

    /// 执行一整行命令；回包 ok = 已受理，结果从订阅流来。
    private func executeCommand(_ line: String) async -> Bool {
        do {
            try await runCommand(client, sessionId: sessionId, line: line)
            return true
        } catch {
            status.set(.failed(step: .executing, cause: .thrown(error)))
            return false
        }
    }
}

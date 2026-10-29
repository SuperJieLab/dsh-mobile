/**
 * 配对页的草稿与提交。
 *
 * **它不认识网关**：提交、问身份、解除都以闭包注入，否则本类无法被断言。失败文案是服务端
 * 原文，且**不清空** `code` —— 打错一位该能改，不该整行重打。
 */
import Foundation

@MainActor
@Observable
final class PairingState {

    var code = ""
    private(set) var isPairing = false
    private(set) var failure: String?

    /// 提交一次配对码；失败抛出，原文显示。落凭证在闭包那一侧（组合根接到 `pairDevice`）。
    private let submit: (String) async throws -> Void
    /// 现在有没有身份 —— 决定画不画「解除配对」。
    ///
    /// **必须读穿到可观察对象**（`CredentialStore.hasDeviceToken`）。读进 `@State` 或只在
    /// `onAppear` 读一次，解除之后这一页不会重算 —— 而那种错不会编译报错。
    private let hasIdentity: () -> Bool
    /// 清凭证与在手票 —— 两半一起，只清凭证会留下「有票没凭证」的窗口。
    private let discardIdentity: () -> Void

    init(submit: @escaping (String) async throws -> Void,
         hasIdentity: @escaping () -> Bool,
         discardIdentity: @escaping () -> Void) {
        self.submit = submit
        self.hasIdentity = hasIdentity
        self.discardIdentity = discardIdentity
    }

    // MARK: - 判定

    /// **只判长度，不判字符集**：码由服务端发放，前端若比它更严，用户粘贴一个带字母的码时
    /// 会看到按钮灰着、却没有任何解释 —— 比「点一次，让服务端说它不行」更糟。
    var canPair: Bool {
        !isPairing && code.count == 6
    }

    var hasLinkedIdentity: Bool { hasIdentity() }

    // MARK: - 动作

    func pair() async {
        isPairing = true
        defer { isPairing = false }
        failure = nil
        do {
            try await submit(code)
            code = ""
        } catch {
            // 服务端的说法原样给用户（码不对 / 过期 / 作废），不翻译。
            failure = error.localizedDescription
        }
    }

    /// 确认对话框在视图那一侧 —— 本类只执行，不询问。
    func unlink() {
        discardIdentity()
    }
}

/// 用 Mac 屏幕上的一次性码换设备凭证，换到就把关系落下。
///
/// 请求在这里拼、回包在这里读；「关系成立」那一步只把凭证交给 `CredentialStore` ——
/// 它是身份的唯一出处，写入即可观察，没有第二份状态要对齐。
@MainActor
func pairDevice(_ client: RpcClient, code: String, into credentials: CredentialStore) async throws {
    let response: PairResponse = try await client.perform(
        PairRequest(code: code), authenticated: false
    )
    guard let deviceToken = response.deviceToken else {
        throw RpcClientError.malformedResponse(detail: "deviceToken")
    }
    credentials.saveDeviceToken(deviceToken)
    Log.info(Log.Module.gateway, "paired — device token stored")
}

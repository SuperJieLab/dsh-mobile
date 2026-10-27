/**
 * 配对那一段的状态：能不能点、点着没有、失败说了什么、要不要显示「解除」。
 *
 * **它不认识网关。** 三件事都以闭包注入：提交一次配对码、问「现在有没有身份」、解除身份。
 * 这不是为了少写几行 —— 收 `RpcClient` 的话本类无法被断言（它是 `final class`、没有协议），
 * 于是「失败不清空输入」「提交中不能重复点」「提交真被调用」这些纪律只能靠人记。
 * 与 `MeshSetupState` 同形：一屏的草稿加一个提交动作，断言只喂闭包。
 *
 * `code` 可写（`TextField` 双向绑定），`isPairing` / `failure` 只读 —— 输入是用户的，
 * 那两个是提交的下场。
 *
 * 失败文案是服务端原文，且**不清空** `code`：改一位再试。配对成功后凭证由注入的提交动作
 * 落定，「现在显示什么」不在本类判断 —— 否则会出现第二个真相来源。
 */
import Foundation

@MainActor
@Observable
final class PairingState {

    var code = ""
    private(set) var isPairing = false
    private(set) var failure: String?

    /// 提交一次配对码。成功即返回；失败抛出，原样显示它的说法。
    ///
    /// 落凭证那一步在闭包那一侧（组合根接线到 `pairDevice`）：本类不该知道凭证存在哪，
    /// 也不该知道协议长什么样。
    private let submit: (String) async throws -> Void
    /// 现在有没有身份 —— 决定要不要画「解除配对」。
    ///
    /// **它必须是一条读穿到可观察对象的闭包**（`CredentialStore.hasDeviceToken`）。
    /// 若把它读进 `@State` 或在 `onAppear` 里读一次，解除之后这一页不会重算 —— 而那种错
    /// 不会编译报错。
    private let hasIdentity: () -> Bool
    /// 解除身份：清掉本机凭证与在手票。
    private let discardIdentity: () -> Void

    init(submit: @escaping (String) async throws -> Void,
         hasIdentity: @escaping () -> Bool,
         discardIdentity: @escaping () -> Void) {
        self.submit = submit
        self.hasIdentity = hasIdentity
        self.discardIdentity = discardIdentity
    }

    // MARK: - 判定

    /// 可提交吗 —— 满 6 位且没有正在进行的提交。
    ///
    /// **只判长度，不判字符集**：配对码由服务端发放，前端若比服务端更严，用户粘贴一个带字母
    /// 的码时会看到按钮灰着、却没有任何解释 —— 比「点一次，让服务端说它不行」更糟。
    ///
    /// 就地判而不另立规则类型：它没有独立于这两个输入的决定。
    var canPair: Bool {
        !isPairing && code.count == 6
    }

    /// 有身份吗 —— 决定画不画「解除配对」。
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
            // 服务端的话原样显示（配对码不对 / 过期 / 作废）。
            failure = error.localizedDescription
        }
    }

    /// 解除 —— 一行转发到注入的动作。确认对话框在视图那一侧。
    func unlink() {
        discardIdentity()
    }
}

/// 用 Mac 屏幕上的一次性配对码换设备凭证，换到就把关系落下。
///
/// 请求在这里拼、回包在这里读；**「关系成立」那一步只把凭证交给 `CredentialStore`** ——
/// 它是身份的唯一出处，写入即生效（可观察），没有第二份状态要对齐。
///
/// 它从 `PairingState` 里独立出来的理由：本类要起网关、要协议，而配对状态那一层不该认识
/// 这些 —— 组合根把它接到 `PairingState.submit` 上。
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

/**
 * 配对码那一段的状态：能不能点、点着没有、失败说了什么。
 *
 * 只装配对码与提交。组网段（地址与接入密钥、保存并接入、节点五态）留在视图里 —— 那条路径
 * 是「视图 → 连接域」两跳，中间插一层只是转发，那种层没有决定权。
 *
 * `code` 可写（`TextField` 双向绑定），`isPairing` / `failure` 只读 —— 输入是用户的，
 * 那两个是提交的下场。
 *
 * 失败文案是服务端原文，且**不清空** `code`：改一位再试。配对成功后由门面翻 `isPaired`，
 * 视图自己让位给列表 —— 这里不判断「配好之后显示什么」，否则会出现第二个真相来源。
 */
import Foundation

@MainActor
@Observable
final class PairingState {

    var code = ""
    private(set) var isPairing = false
    private(set) var failure: String?

    private let client: RpcClient

    init(client: RpcClient) {
        self.client = client
    }

    /// 可点吗 —— 一行转发到 `PairingRules`。按钮的内容与 `disabled` 都读它。
    ///
    /// 规则不写在这里：它要能在没有界面、没有网关的条件下被断言，而本类型的构造要一个
    /// `RpcClient`（`final class`、没有协议）。输入仍归这里 —— `code` 与 `isPairing`。
    var canPair: Bool {
        PairingRules.canSubmitCode(code, isSubmitting: isPairing)
    }

    func pair() async {
        isPairing = true
        defer { isPairing = false }
        failure = nil
        do {
            try await pairDevice(client, code: code)
            code = ""
        } catch {
            // 服务端的话原样显示（配对码不对 / 过期 / 作废）。
            failure = error.localizedDescription
        }
    }
}

/// 用 Mac 屏幕上的一次性配对码换设备凭证，换到就把关系落下。
///
/// 请求在这里拼、回包在这里读；**「关系成立」那一步不在这里** —— 它只把凭证交给
/// `RpcClient.adopt`，因为身份状态的唯一写者是那一层。
@MainActor
func pairDevice(_ client: RpcClient, code: String) async throws {
    let response: PairResponse = try await client.perform(
        PairRequest(code: code), authenticated: false
    )
    guard let deviceToken = response.deviceToken else {
        throw RpcClientError.malformedResponse(detail: "deviceToken")
    }
    client.adopt(deviceToken: deviceToken)
}

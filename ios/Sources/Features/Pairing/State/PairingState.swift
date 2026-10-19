/**
 * 配对码那一段的状态：能不能点、点着没有、失败说了什么。
 *
 * 只装配对码与提交。组网段（地址与接入密钥、保存并接入、节点五态）留在视图里 —— 那条路径
 * 是「视图 → 连接域」两跳，中间插一层只是转发，那种层没有决定权，应当并回上一层。
 *
 * `code` 可写（`TextField` 双向绑定），`isPairing` / `failure` 只读 —— 不对称是刻意的：
 * 输入是用户的，那两个是提交的下场。
 *
 * 失败文案是服务端原文，且**不清空** `code`：用户可以改一位再试（与「看得见为什么不行」
 * 的纪律一致）。配对成功后由门面翻 `isPaired`，视图自己让位给列表 —— 这里不判断「配好之后
 * 显示什么」，否则会出现第二个真相来源。
 *
 * `State` 下不 import SwiftUI —— 判据在 `tests/LayeringTests.swift`。
 */
import Combine
import Foundation

@MainActor
final class PairingState: ObservableObject {

    @Published var code = ""
    @Published private(set) var isPairing = false
    @Published private(set) var failure: String?

    private let client: GatewayClient

    init(client: GatewayClient) {
        self.client = client
    }

    /// 可点吗 —— 一行转发到 `PairingRules`。按钮的内容与 `disabled` 都读它。
    ///
    /// 规则不写在这里：它要能在没有界面、没有网关的条件下被断言，而本类型的构造要一个
    /// `GatewayClient`（`final class`、没有协议）。输入仍归这里 —— `code` 与 `isPairing`。
    var canPair: Bool {
        PairingRules.canSubmitCode(code, isSubmitting: isPairing)
    }

    func pair() async {
        isPairing = true
        defer { isPairing = false }
        failure = nil
        do {
            try await client.pair(code: code)
            code = ""
        } catch {
            // 服务端的话原样显示（配对码不对 / 过期 / 作废）。
            failure = error.localizedDescription
        }
    }
}

import SwiftUI

/// 配对屏（M4）：用 Mac 屏幕上的一次性配对码建立关系。
///
/// 全 App 唯一需要用户「在场」的动作，也是唯一一段不需要身份的通信 —— 配对码本身就是凭证
/// （一次性、10 分钟、错 5 次作废，限次与时效都在服务端）。成功后设备凭证进 Keychain，
/// 之后一切请求静默带票。
struct PairingView: View {
    let client: GatewayClient

    @State private var code = ""
    @State private var failure: String?
    @State private var isPairing = false

    var body: some View {
        Form {
            Section {
                Text("在 Mac 的 dsh 终端日志里找到 6 位配对码（启动时打印，10 分钟内有效）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("6 位配对码", text: $code)
                    .keyboardType(.numberPad)
                    .disabled(isPairing)

                Button {
                    Task { await pair() }
                } label: {
                    if isPairing {
                        ProgressView()
                    } else {
                        Text("配对")
                    }
                }
                .disabled(isPairing || code.count != 6)
            }

            if let failure {
                Section {
                    FailureBanner(text: failure)
                }
            }
        }
        .navigationTitle("配对")
    }

    private func pair() async {
        isPairing = true
        defer { isPairing = false }
        failure = nil
        do {
            try await client.pair(code: code)
            code = ""
        } catch {
            // 服务端的话原样显示（配对码不对 / 过期 / 作废）——
            // 与 M0 起「看得见为什么不行」的纪律一致。
            failure = error.localizedDescription
        }
    }
}

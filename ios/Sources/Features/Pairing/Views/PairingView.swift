import SwiftUI

/// 配对屏：用 Mac 屏幕上的一次性配对码建立关系。
///
/// 全 App 唯一需要用户「在场」的动作，也是唯一一段不需要身份的通信 —— 配对码本身就是凭证
/// （一次性、10 分钟、错 5 次作废，限次与时效都在服务端）。成功后设备凭证进沙盒存储，
/// 之后一切请求静默带票。
///
/// **只装配对码这一段**。组网（地址、接入密钥、节点五态）在 `MeshSettingsView`：那一段在
/// 已配对之后还要常驻可达，两件事的生命周期不同。挤在一个视图里时，已配对状态打开设置页，
/// 标题是「配对」、上面还挂着「输入 6 位配对码 + 配对按钮」。
struct PairingView: View {
    let state: PairingState

    @ViewBuilder
    var body: some View {
        // 局部 `@Bindable`：观察对象本身没有 `$`，取属性绑定要再包一次。
        @Bindable var state = state
        Form {
            Section {
                Text("在 Mac 的 dsh 终端日志里找到 6 位配对码（启动时打印，10 分钟内有效）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("6 位配对码", text: $state.code)
                    .keyboardType(.numberPad)
                    .disabled(state.isPairing)

                Button {
                    Task { await state.pair() }
                } label: {
                    if state.isPairing {
                        ProgressView()
                    } else {
                        Text("配对")
                    }
                }
                .disabled(!state.canPair)
            }

            if let failure = state.failure {
                Section {
                    FailureBanner(text: failure)
                }
            }
        }
        .navigationTitle("配对")
        .scrollDismissesKeyboard(.immediately)
    }
}

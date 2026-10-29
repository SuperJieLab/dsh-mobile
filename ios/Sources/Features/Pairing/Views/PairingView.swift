import SwiftUI

/// 配对页的**渲染段**：配对码 + 解除。零闭包，只读容器。
/// 全 App 唯一需要用户「在场」的动作，也是唯一一段不需要身份的通信 —— 配对码本身就是凭证
/// 组网不在这里：那是换路径，这是换身份。两者在设置页里并列。
struct PairingView: View {
    let state: PairingState

    /// 解除不可逆（要重新拿配对码），所以走一次确认。
    @State private var confirmingUnlink = false

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

            // 身份的另一半：结束这段关系。只在有身份时出现 —— 没有的时候没什么可解除的。
            if state.hasLinkedIdentity {
                Section {
                    Button("解除配对", role: .destructive) {
                        confirmingUnlink = true
                    }
                } footer: {
                    Text("解除后要用新的配对码重新建立关系。")
                }
            }
        }
        .navigationTitle("配对")
        .scrollDismissesKeyboard(.immediately)
        .confirmationDialog("解除后要用新的配对码重新建立关系，确定吗？",
                            isPresented: $confirmingUnlink,
                            titleVisibility: .visible) {
            Button("解除配对", role: .destructive) { state.unlink() }
            Button("取消", role: .cancel) {}
        }
    }
}

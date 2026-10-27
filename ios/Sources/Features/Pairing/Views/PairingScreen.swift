import SwiftUI

/// 配对屏的装配段：造容器、交给渲染段。容器随这一屏生死。
///
/// **草稿不跨进出存活**：6 位码 10 分钟失效，输一半退出再进来看到上次那半截码是陷阱，
/// 不是体贴。所以 `PairingState` 住 `@State` —— 由组合根给的闭包造（它才知道凭证在哪），
/// 而容器本身的寿命跟这一屏。
///
/// 渲染段拿不到任何闭包：它只读 `PairingState`。
struct PairingScreen: View {
    private let make: () -> PairingState
    @State private var state: PairingState?

    init(make: @escaping () -> PairingState) {
        self.make = make
    }

    var body: some View {
        Group {
            if let state {
                PairingBody(state: state)
            } else {
                // 首帧：容器还没造出来。`@State` 的初值在 `init` 里求值，那一刻拿不到环境；
                // 也不该由上一级替它造（那会每次重算白造一个，而 `@State` 只采用第一个）。
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if state == nil { state = make() } }
    }
}

/// 配对页的渲染段：配对码 + 解除。零闭包，只读容器。
///
/// 全 App 唯一需要用户「在场」的动作，也是唯一一段不需要身份的通信 —— 配对码本身就是凭证
/// （一次性、10 分钟、错 5 次作废，限次与时效都在服务端）。成功后设备凭证落沙盒，
/// 之后一切请求静默带票。
///
/// 组网（地址、接入密钥、节点五态）不在这里：那是换路径，这是换身份。两者在设置页里并列，
/// 因为修法完全不同 —— 而配对的另一半（解除）在这一页，它是同一对迁移的反向。
struct PairingBody: View {
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

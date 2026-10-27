import SwiftUI

/// 配对屏：用 Mac 屏幕上的一次性配对码建立关系。
///
/// 全 App 唯一需要用户「在场」的动作，也是唯一一段不需要身份的通信 —— 配对码本身就是凭证
/// （一次性、10 分钟、错 5 次作废，限次与时效都在服务端）。成功后设备凭证进沙盒存储，
/// 之后一切请求静默带票。
///
/// 两个状态源各管一段，本文件只绑、只画：
/// - `PairingState`：配对码那一段（可用性、进行中、失败原文）。
/// - `MeshSetupState`：组网那一段（两份地址与接入密钥、能不能保存、保存并接入）。
///
/// 它们分开是因为换的不是同一件事 —— 一个换身份，一个换路径，失败域也不同。组网段
/// 原先自己持输入、自己写盘、自己判能不能提交，于是视图既读盘又写盘；现在这些都在
/// 那个状态里，本文件不认识 `MeshConfig`，也碰不到磁盘。
struct PairingView: View {
    /// 根部注入：这一屏的配对码状态被三条路径共用（未配对时的整屏、列表的组网设置、
    /// 详情的组网设置）。共用是安全的 —— `pair()` 成功时清 `code`、`failure` 只在下次
    /// 提交时清，于是不会把上一次的配对码带进来。
    @Environment(PairingState.self) private var state
    /// 根部注入：组网录入。同样三条路径共用一份草稿 —— 同一台设备只有一份组网配置。
    @Environment(MeshSetupState.self) private var mesh
    /// 组网段的展示数据源 —— 节点五态与「配置读坏了」都经 store 转发（只读，不动手）。
    @Environment(MeshStore.self) private var store

    @ViewBuilder
    var body: some View {
        // 局部 `@Bindable`：`@Environment` 给的观察对象没有 `$`，取属性绑定要再包一次。
        @Bindable var state = state
        Form {
            meshSection

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
        // 共用一份状态：打开时清掉别处留下的失败横幅（理由见 `resetFeedback`）。
        // 挂 `onAppear` 而不是写在 body 里：body 求值期间写状态就是「渲染中改状态」。
        .onAppear { state.resetFeedback() }
    }

    // MARK: - 组网段

    @ViewBuilder
    private var meshSection: some View {
        @Bindable var mesh = mesh
        Section("组网") {
            // 存过但读不出来：与「从没配过」分开说，否则用户会去查证书而不是重填。
            if store.storedConfigDamaged {
                Text("保存的组网配置读取失败，请重新填写下面两项再保存。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            switch store.nodeState {
            case .noKey:
                Text("输入组网服务地址与接入密钥（Mac 上 `headscale preauthkeys create` 生成）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .registering:
                HStack { ProgressView(); Text("注册中…") }

            case .running:
                Label("已入虚拟网", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .failed(.badKey):
                Text("密钥无效或过期，请在 VPS 上重新生成后重试。")
                    .foregroundStyle(.red)

            case .failed(.unreachable):
                Text("组网服务不可达。先确认地址正确、iPhone 已安装并信任 CA 描述文件。")
                    .foregroundStyle(.red)
            }

            TextField("https://<组网服务地址>:8443", text: $mesh.controlURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("http://<网关 tailnet 地址>:3081", text: $mesh.gatewayURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            // 明文展示（用户要求）：key 要「看得见才敢确认贴对了」，粘错是本轮
            // 排障的主要嫌疑；个人设备场景下明文可接受（凭证本就存沙盒明文）。
            TextField("接入密钥（hskey-auth-…）", text: $mesh.tailnetKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Button("保存并接入") {
                    Task { await mesh.saveAndConnect() }
                }
                .disabled(!mesh.canSubmit)

                if case .failed = store.nodeState {
                    Button("重试") {
                        Task { await mesh.retryMesh() }
                    }
                }
            }
        }
    }
}

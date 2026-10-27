import SwiftUI

/// 配对屏：用 Mac 屏幕上的一次性配对码建立关系。
///
/// 全 App 唯一需要用户「在场」的动作，也是唯一一段不需要身份的通信 —— 配对码本身就是凭证
/// （一次性、10 分钟、错 5 次作废，限次与时效都在服务端）。成功后设备凭证进沙盒存储，
/// 之后一切请求静默带票。
///
/// 配对码那一段的状态在 `PairingState`（可用性、进行中、失败原文），本文件只绑。
/// 组网段是「视图 → 连接域」两跳，不另立一层：headscale 地址与接入 key
/// （沙盒存储）在此录入，节点状态如实展示；配对仍走原三票身份（不因在虚拟网内简化）。
struct PairingView: View {
    @State private var state: PairingState
    /// 组网段的数据源 —— 视图读连接态的唯一出口，节点状态与动作都经 store 转发。
    @Environment(MeshStore.self) private var store

    @State private var controlURL = MeshConfig.load().controlURLString
    @State private var gatewayURL = MeshConfig.load().gatewayURLString
    @State private var tailnetKey = ""

    init(client: RpcClient) {
        _state = State(initialValue: PairingState(client: client))
    }

    @ViewBuilder
    var body: some View {
        // 局部 `@Bindable`：`@State` 的 `$` 只到对象这一层，取属性绑定要再包一次。
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
    }

    // MARK: - 组网段

    @ViewBuilder
    private var meshSection: some View {
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

                TextField("https://<组网服务地址>:8443", text: $controlURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("http://<网关 tailnet 地址>:3081", text: $gatewayURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                // 明文展示（用户要求）：key 要「看得见才敢确认贴对了」，粘错是本轮
                // 排障的主要嫌疑；个人设备场景下明文可接受（凭证本就存沙盒明文）。
                TextField("接入密钥（hskey-auth-…）", text: $tailnetKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button("保存并接入") {
                        MeshConfig(controlURLString: controlURL, gatewayURLString: gatewayURL).save()
                        // 先捕获值再清空输入框：Task 闭包执行时才读 tailnetKey，
                        // 顺序反了提交永远是空串。
                        let key = tailnetKey
                        tailnetKey = ""
                        Task { await store.submitMeshKey(key, config: MeshConfig.load()) }
                    }
                    .disabled(!PairingRules.canSubmitMesh(
                        key: tailnetKey,
                        config: MeshConfig(controlURLString: controlURL, gatewayURLString: gatewayURL)
                    ))

                    if case .failed = store.nodeState {
                        Button("重试") {
                            Task { await store.retryMesh(config: MeshConfig.load()) }
                        }
                    }
                }
        }
    }
}

import SwiftUI

/// 配对屏（M4）：用 Mac 屏幕上的一次性配对码建立关系。
///
/// 全 App 唯一需要用户「在场」的动作，也是唯一一段不需要身份的通信 —— 配对码本身就是凭证
/// （一次性、10 分钟、错 5 次作废，限次与时效都在服务端）。成功后设备凭证进沙盒存储（M8 后注），
/// 之后一切请求静默带票。
///
/// M8 追加组网段（决定 5 / 决定 8）：headscale 地址与接入 key（沙盒存储）在此录入，
/// 节点状态如实展示；配对仍走原三票身份（决定 9，不因在虚拟网内简化）。
struct PairingView: View {
    let client: GatewayClient
    /// 组网段的数据源 —— App 根部创建并经 environmentObject 注入（T7 接线）。
    @EnvironmentObject private var node: TailnetNode

    @State private var code = ""
    @State private var failure: String?
    @State private var isPairing = false

    @State private var controlURL = MeshConfig.load().controlURLString
    @State private var gatewayURL = MeshConfig.load().gatewayURLString
    @State private var tailnetKey = ""

    var body: some View {
        Form {
            meshSection

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
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - 组网段（M8）

    @ViewBuilder
    private var meshSection: some View {
        Section("组网") {
                switch node.state {
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
                        // 顺序反了提交永远是空串（真机 T8 日志实锤的竞态）。
                        let key = tailnetKey
                        tailnetKey = ""
                        Task { await node.submitKey(key, config: MeshConfig.load()) }
                    }
                    .disabled(tailnetKey.isEmpty || !MeshConfig(controlURLString: controlURL, gatewayURLString: gatewayURL).isComplete)

                    if case .failed = node.state {
                        Button("重试") {
                            Task { await node.retry(config: MeshConfig.load()) }
                        }
                    }
                }
        }
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

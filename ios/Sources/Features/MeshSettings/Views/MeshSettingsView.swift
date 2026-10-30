import SwiftUI

/// 组网设置：两台机器之间的路径（组网服务地址、网关地址、接入密钥）与节点五态。
/// 与配对屏分开，因为换的不是同一件事：配对换**身份**（一次性，未配对时才有意义），
/// 本文件只是渲染段：草稿由 `MeshSettingsAssembler` 造，节点事实由 `store` 给。
struct MeshSettingsView: View {
    @Bindable var setup: MeshSetupState
    /// 节点五态与「配置读坏了」的来源。只读 —— 动手的入口在 `setup`。
    let store: MeshStore

    var body: some View {
        Form {
            Section("组网") {
                // 存过但读不出来：与「从没配过」分开说，否则用户会去查证书而不是重填。
                if store.storedConfigDamaged {
                    Text("保存的组网配置读取失败，请重新填写下面两项再保存。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                switch store.nodeState {
                case .noKey:
                    Text("填接入密钥就能接入。组网服务留空即用官方 Tailscale；网关地址填 Mac 的虚拟网 IP。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                case .registering:
                    HStack { ProgressView(); Text("注册中…") }

                case .running:
                    // `.running` 只说明「上次注册过、这次不必重新注册」—— 冷启动时状态机在
                    // `up()` **之前**就给出它（判据只是状态目录可读），而 tsnet 此刻可能正
                    // 卡在连控制面。**绿勾必须等隧道真的建成**，判据是 `phase`：
                    // `.running` 加「还没有隧道产物」会被折成 `.connecting`。
                    if case .ready = store.phase {
                        Label("已入虚拟网", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack { ProgressView(); Text("正在接入虚拟网…") }
                    }

                case .failed(.badKey):
                    Text("密钥无效或过期，在组网服务的后台重新生成后重试。")
                        .foregroundStyle(.red)

                case .failed(.unreachable):
                    Text("组网服务不可达。确认网关地址填对；自建服务还要 iPhone 已信任它的 CA 描述文件。")
                        .foregroundStyle(.red)
                }

                TextField("留空 = 官方 Tailscale（https://controlplane.tailscale.com）",
                          text: $setup.controlURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("http://100.x.y.z:3081（Mac 上 tailscale ip -4）", text: $setup.gatewayURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                // 明文展示（用户要求）：key 要「看得见才敢确认贴对了」，粘错是排障的主要
                // 嫌疑；个人设备场景下明文可接受（凭证本就存沙盒明文）。
                TextField("接入密钥（tskey-auth-… 或 hskey-auth-…）", text: $setup.tailnetKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button("保存并接入") {
                        Task { await setup.saveAndConnect() }
                    }
                    .disabled(!setup.canSubmit)

                    if case .failed = store.nodeState {
                        Button("重试") {
                            Task { await setup.retryMesh() }
                        }
                    }
                }

                // 被拒的原因由状态给（它知道「为什么没提交」），措辞与渲染各归各家。
                if let reason = setup.blockedReason {
                    Text(reason.text)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("组网")
    }
}

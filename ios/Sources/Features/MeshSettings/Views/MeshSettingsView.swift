import SwiftUI

/// 组网设置：两台机器之间的路径（组网服务地址、网关地址、接入密钥）与节点五态。
///
/// 与配对屏分开，因为换的不是同一件事：配对换**身份**（一次性，未配对时才有意义），
/// 组网换**路径**（已配对之后照样要改地址、看节点起没起来）。挤在一个视图里时，
/// 已配对状态打开这一页，标题是「配对」、上面还挂着「输入 6 位配对码」。
///
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

                TextField("https://<组网服务地址>:8443", text: $setup.controlURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("http://<网关 tailnet 地址>:3081", text: $setup.gatewayURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                // 明文展示（用户要求）：key 要「看得见才敢确认贴对了」，粘错是排障的主要
                // 嫌疑；个人设备场景下明文可接受（凭证本就存沙盒明文）。
                TextField("接入密钥（hskey-auth-…）", text: $setup.tailnetKey)
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
            }
        }
        .navigationTitle("组网")
    }
}

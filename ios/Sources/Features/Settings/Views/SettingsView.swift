import SwiftUI

/// 设置：两个常驻入口 —— 组网（路径）与身份（凭证）。
///
/// **入口只在这里**：未就绪时界面本身就是组网配置页（那一面只有一件事可做），会话详情只
/// 展示组网事实、不提供配置入口。两个入口共用同一个配置页，只是抵达路径不同。
struct SettingsView: View {
    let state: SettingsState

    /// 解除配对不可逆（要重新拿配对码），所以走一次确认。
    @State private var confirmingUnlink = false

    var body: some View {
        Form {
            Section("接入") {
                NavigationLink {
                    MeshSettingsView(state: state.meshSettings)
                } label: {
                    LabeledContent("组网", value: state.meshSummary)
                }
            }

            Section("身份") {
                LabeledContent("状态", value: state.isPaired ? "已配对" : "未配对")
                if state.isPaired {
                    Button("解除配对", role: .destructive) {
                        confirmingUnlink = true
                    }
                }
            }
        }
        .navigationTitle("设置")
        .confirmationDialog("解除后要用新的配对码重新建立关系，确定吗？",
                            isPresented: $confirmingUnlink,
                            titleVisibility: .visible) {
            Button("解除配对", role: .destructive) { state.unlink() }
            Button("取消", role: .cancel) {}
        }
    }
}

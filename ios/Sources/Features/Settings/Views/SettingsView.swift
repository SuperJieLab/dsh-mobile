import SwiftUI

/// 设置：两个常驻入口 —— 组网（路径）与身份（凭证）。
/// **配置动作只在这里。** 列表页永远在，前置不满足时它只在顶部提示；用户要修的东西在
/// 身份的两个方向都在配对页里：配对（建立）与解除（结束），`adopt` 与 `sever` 是同一对
/// 迁移的两半。
struct SettingsView: View {
    let state: SettingsState

    var body: some View {
        Form {
            Section("接入") {
                NavigationLink(value: Destination.mesh) {
                    LabeledContent("组网", value: state.meshSummary)
                }
            }

            Section("身份") {
                LabeledContent("状态", value: state.isPaired ? "已配对" : "未配对")
                NavigationLink(value: Destination.pairing) {
                    Text("配对")
                }
            }
        }
        .navigationTitle("设置")
    }
}

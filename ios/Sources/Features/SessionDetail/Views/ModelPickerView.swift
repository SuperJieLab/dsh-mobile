import SwiftUI

/// 模型选择按钮：功能条中间那一格。
///
/// 它只负责「显示当前是什么 + 点开一个入口」—— 模型列表与推理等级都在 `ModelSheetView` 里。
/// 那两件事需要一个页面（模型列表 + 该模型的设置），一格按钮的下拉装不下：把模型与等级
/// 平级塞进菜单，会让「换模型」这个主用途先遇到一次入口选择。
struct ModelPickerView: View {

    /// 宿主算好的显示名（「模型名 · 等级名」）。
    let label: String
    /// 点一下做什么。打开哪个面由宿主决定。
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

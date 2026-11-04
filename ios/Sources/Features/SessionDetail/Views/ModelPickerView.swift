import SwiftUI

/// 模型选择按钮：功能条中间那一格。
/// 它只负责「显示当前是什么 + 点开一个入口」—— 模型列表与推理等级都在 `ModelSheetView` 里。
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

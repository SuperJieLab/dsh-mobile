import SwiftUI

/// 上下文占用：一行读数，点开看组成三项（M6）。
///
/// 复现对象是上游 composer 旁的占用面板（`ContextMeter.tsx`），只把那个环换成一
/// 行 —— 窄屏上没有环的位置，读数本身才是要传达的。呈现规则全部照上游：
///
/// - 百分比与紧凑数字（换算在 `UsagePayload.percent` / `.figures` 里，判据 O2）
/// - 「约」无条件加，不区分数字来自哪个投影字段（§3.1 决定 5）
/// - **组成缺省时不出展开区，比例照常显示**（判据 U8）；三行文案用上游的中文
///   （`ui-conversation/src/client/locales.ts:63-65`）
///
/// ⚠️ 本视图只在有读数时被挂上 —— 「没有读数」与「占用 0%」不是一回事，
/// 判空归调用方（`SessionDetailView`），这样这里永远不做空态。
struct OccupancyBar: View {
    let usage: UsagePayload

    @State private var expanded = false

    /// 组成三项（文案照上游）。缺组成时为空 —— 展开区与折叠箭头都不出现。
    private var rows: [CompositionRow] {
        guard let breakdown = usage.breakdown else { return [] }
        return [
            CompositionRow(label: "系统提示词", tokens: breakdown.systemTokens),
            CompositionRow(label: "工具定义", tokens: breakdown.toolsTokens),
            CompositionRow(label: "对话消息", tokens: breakdown.messageTokens),
        ]
    }

    /// 用 `Identifiable` 而不是 `id: \.label` —— Swift 的 key path 不能指向
    /// 元组成员，拿元组数组直接喂 `ForEach` 编不过。
    private struct CompositionRow: Identifiable {
        var id: String { label }
        let label: String
        let tokens: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("\(usage.percent)%")
                        .font(.caption)
                        .monospacedDigit()
                    Text(usage.figures)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if !rows.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(rows.isEmpty)
            .accessibilityLabel("上下文已用 \(usage.percent)%")

            if expanded && !rows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        HStack(spacing: 6) {
                            Text(row.label)
                            Text("~\(formatTokens(row.tokens))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                    }
                }
                .padding(.leading, 10)
            }
        }
    }
}

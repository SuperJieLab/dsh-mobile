import SwiftUI

/// 一次工具调用的行。
///
/// 两级：这一行自己管「细节显示不显示」（点开看模型给的原始参数与工具返回的结果）。
/// 至于「本轮的过程显示不显示」，由外层的 `TurnProcessRow` 管（§3.2 决定 9）。
///
/// 形态对所有工具统一 —— 不按工具类型做专用卡片：手机屏幕窄，专用卡片带来的
/// 信息密度提升抵不过要维护的十几种形态（§1.3）。
struct ToolRowView: View {

    let row: ToolRow

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.icon(for: row.status))
                        .font(.caption)
                        .foregroundStyle(Self.tint(for: row.status))
                    Text(row.name ?? "工具")
                        .font(.footnote.weight(.medium))
                    if let summary = row.summary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Text(Self.label(for: row.status))
                        .font(.caption2)
                        .foregroundStyle(Self.tint(for: row.status))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let errorCode = row.errorCode {
                        Text(errorCode)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Self.tint(for: .failed))
                    }
                    if let arguments = row.argumentsRaw, !arguments.isEmpty {
                        DetailBlock(title: "参数", text: arguments)
                    }
                    if let result = row.resultText, !result.isEmpty {
                        DetailBlock(title: "结果", text: result)
                    }
                    if row.argumentsRaw == nil && row.resultText == nil && row.errorCode == nil {
                        // 半截形态（`tool/call` 在窗口外）：如实说「不知道」，
                        // 而不是画一个空的展开区让人以为工具什么都没返回。
                        Text("这一行来自窗口之外 —— 它的调用参数不在本地。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    private static func icon(for status: ToolRow.Status) -> String {
        switch status {
        case .running: return "circle.dotted"
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .interrupted: return "slash.circle"
        }
    }

    private static func tint(for status: ToolRow.Status) -> Color {
        switch status {
        case .running: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        case .interrupted: return .orange
        }
    }

    private static func label(for status: ToolRow.Status) -> String {
        switch status {
        case .running: return "运行中"
        case .succeeded: return "成功"
        case .failed: return "失败"
        // 「中断」不是「失败」：失败说明工具跑了并出错，中断说明我们不知道它怎么了。
        case .interrupted: return "中断"
        }
    }
}

/// 展开区里的一段等宽文本（原始参数 / 工具结果）。
private struct DetailBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(display.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = display.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 8))
    }

    /// 超长内容截断**并明说** —— 静默丢掉半段结果，比明确说「这里截了」危险得多。
    private var display: (text: String, note: String?) {
        guard text.count > Self.limit else { return (text, nil) }
        let head = String(text.prefix(Self.limit))
        return (head, "已截断 · 完整内容共 \(text.count) 字符")
    }

    /// 照上游的展示上限（`ui-chat` 的 `MAX_CHARS = 2e4`）。
    private static let limit = 20_000
}

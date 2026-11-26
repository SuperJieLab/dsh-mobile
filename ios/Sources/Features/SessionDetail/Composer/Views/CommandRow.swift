import SwiftUI

/// 消息流里的一条命令：按了什么、现在什么结果。
/// 它不套气泡：命令不是某人的发言，是一次动作。视觉上靠左侧一条竖线与对话区分，
/// 三种状态各有说法：**执行中**（还没等到 `command/done`）、**成功**、**失败**。
struct CommandRow: View {

    let run: CommandRun

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.name.isEmpty ? "命令" : run.invocation)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let outcome = detailedText {
                    Text(outcome)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// 结果那半句。执行中没有；成功与失败各自带不带宿主原文都可能。
    private var detailedText: String? {
        switch run.outcome {
        case nil: return "执行中…"
        case .success(let text): return text?.isEmpty == false ? text : "已完成"
        case .failure(let text): return text?.isEmpty == false ? text : "未成功"
        }
    }

    private var icon: String {
        switch run.outcome {
        case nil: return "ellipsis.circle"
        case .success: return "checkmark.circle"
        case .failure: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch run.outcome {
        case nil: return .secondary
        case .success: return .accentColor
        case .failure: return .orange
        }
    }
}

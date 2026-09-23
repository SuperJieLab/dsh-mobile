import SwiftUI

/// 一轮的过程：折叠头（一行摘要）+ 展开后的过程行。
///
/// 默认收起 —— 一轮里二十次工具调用、几千字思考，铺开来会把对话本身淹掉。
/// 最终答案**不在**折叠里（组装器已把它划成独立的节点），所以收起后这一屏
/// 读起来就是「你说什么 → 它做了什么 → 它答什么」（§3.2 决定 10）。
struct TurnProcessRow: View {

    let process: NodeProcess

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if process.hasHeader, let summary = process.summary {
                header(summary)
                if expanded { entries }
            } else {
                // 没有折叠头就收起不了 —— 窗口切半的那一组（`turn/start` 不在窗口里）
                // 仍如实平铺：它的过程是真的发生了，只是这一轮的开头不在这里（判据 A7）。
                entries
            }
        }
        .padding(.vertical, 2)
    }

    private func header(_ summary: String) -> some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                Text(summary)
                    .font(.footnote)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var entries: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(process.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .thinking(_, let text, _):
                    ThinkingRow(text: text)
                case .tool(let row):
                    ToolRowView(row: row)
                case .text(_, let text, _):
                    // 一轮中间的助手文本（不是最终答案的那部分）—— 它也是「说过的话」，
                    // 所以按正文排版，不缩成一行摘要。
                    Text(text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 6)
    }
}

/// 一段思考。默认只露一行——思考常常长过整轮的工具调用，全文铺开会把过程冲掉。
private struct ThinkingRow: View {

    let text: String

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("思考")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .onTapGesture { expanded.toggle() }
    }
}

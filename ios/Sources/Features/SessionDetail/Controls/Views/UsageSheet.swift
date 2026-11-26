import SwiftUI

/// 上下文占用的详情：百分比、读数、三段占比与组成。
///
/// 只吃一份读数 —— 不认识编排，也不认识连接域。没有组成三项时整段不出：
/// 服务端「不知道」组成**不减损**比例，与上游同一条口径。
struct UsageSheet: View {

    /// `nil` = 这个水位上没有读数（一个陈述，不是故障）。
    let usage: UsagePayload?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let usage {
                    content(usage)
                } else {
                    ContentUnavailableView(
                        "没有读数",
                        systemImage: "gauge.with.dots.needle.0percent",
                        description: Text("这一处还没有上下文占用数据 —— 等 DSH 再跑一轮就会出现。")
                    )
                }
            }
            .navigationTitle("上下文占用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func content(_ usage: UsagePayload) -> some View {
        // 包一层 ScrollView：大字号（辅助功能）下这三行会超出 `.medium` 的高度。
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(usage.percentText)
                        .font(.largeTitle.monospacedDigit().weight(.semibold))
                    Text(usage.figures)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if let breakdown = usage.breakdown {
                    VStack(alignment: .leading, spacing: 12) {
                        shareBar(breakdown)
                        VStack(alignment: .leading, spacing: 8) {
                            row("系统提示词", breakdown.systemTokens)
                            row("工具定义", breakdown.toolsTokens)
                            row("对话消息", breakdown.messageTokens)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 三段占比条。宽度按 token 数分配，总和归一到整条 —— 比例本身就是信息，
    /// 不为了好看把它抹平。
    private func shareBar(_ breakdown: UsageBreakdown) -> some View {
        let parts: [(tokens: Int, color: Color)] = [
            (breakdown.systemTokens, .blue),
            (breakdown.toolsTokens, .purple),
            (breakdown.messageTokens, .teal),
        ]
        let total = max(1, parts.reduce(0) { $0 + $1.tokens })
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(0..<parts.count, id: \.self) { index in
                    Rectangle()
                        .fill(parts[index].color)
                        .frame(width: proxy.size.width
                               * CGFloat(parts[index].tokens) / CGFloat(total))
                }
            }
        }
        .frame(height: 8)
        .clipShape(.rect(cornerRadius: 4))
    }

    private func row(_ label: String, _ tokens: Int) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Text("~\(formatTokens(tokens))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}

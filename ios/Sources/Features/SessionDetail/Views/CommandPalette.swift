import SwiftUI

/// 命令候选面板：输入框上方的一块列表。
///
/// 它只在「草稿正在敲命令」时出现（判定在 `SlashTrigger`），点一条就回填草稿 ——
/// **不执行**：用户还要补参数、还要自己按发送。选中即执行会让带参数的命令无法使用。
///
/// 三面与目录同构：等待 / 有内容（含「一条都没有」与「没有匹配」两种）/ 失败 + 重试。
struct CommandPalette: View {

    /// 目录的三面。取数与判定都在里面，这里只读。
    @ObservedObject var directory: CommandDirectory
    /// 过滤用的查询串（`SlashTrigger.querying` 里那一段）。
    let query: String
    /// 选中一条：把回填好的草稿交出去。
    let onPick: (CommandInfo) -> Void

    /// 面板高度上限：给输入框与消息流都留位置，别让候选把整屏占满。
    private static let maxHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: Self.maxHeight, alignment: .top)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch directory.outcome {
        case .waiting:
            ProgressView()
                .controlSize(.small)
                .padding(8)

        case .failed(let cause):
            VStack(alignment: .leading, spacing: 4) {
                Text(cause.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await directory.reload() } }
                    .font(.caption)
            }
            .padding(8)

        case .ready(let commands):
            if commands.isEmpty {
                Text(CommandDirectory.emptyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                let matches = CommandDirectory.match(commands, query: query)
                if matches.isEmpty {
                    Text(CommandDirectory.noMatchNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(matches, id: \.name) { command in
                                row(command)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 一行候选：名字（等宽，与命令行的观感一致）+ 一句说明。
    private func row(_ command: CommandInfo) -> some View {
        Button {
            onPick(command)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("/\(command.name)")
                    .font(.footnote)
                    .monospaced()
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// 连接详情：路径、状态、最后收到数据的时刻、组网节点。
///
/// 只吃值加两个闭包 —— 不认识 `SessionSync`，也不认识 `MeshStore`。
/// 这样它能在预览与测试里独立成立，接线（谁提供这些值）留在宿主。
struct NetworkSheet: View {

    let phase: FollowClient.Phase
    let carrier: CarrierPath?
    /// 进本屏以来收到的最后一帧；`nil` 时这一行整个不出现（不显示「0 秒前」）。
    let lastFrameAt: Date?
    let nodeState: TailnetNodeState
    /// 组网配置存过但读不出来 —— 与「从没配过」分开说。
    let configDamaged: Bool
    let onRetry: () -> Void
    let onOpenMesh: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    row("路径", carrierText)
                    row("状态", phaseText)
                    if let lastFrameAt {
                        row("最后收到数据", relativeTime(lastFrameAt.timeIntervalSince1970 * 1000))
                    }
                }

                Section("组网") {
                    row("节点", nodeText)
                    if configDamaged {
                        Text("保存的组网配置读取失败，请在组网设置里重新填写。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button("重试现在") { onRetry() }
                    Button("组网设置") { onOpenMesh() }
                }
            }
            .navigationTitle("连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// 路径：复用 `ConnectionBadge.look` 的三件套里的说法，不另写一份 case 映射。
    private var carrierText: String {
        carrier.map { ConnectionBadge.look(of: $0).text } ?? "未知"
    }

    /// 状态：传 `nil` 路径给同一个映射 —— 拿到的正是「状态」视角的说法
    /// （已连接 / 连接中… / 重连中…），与功能条那一格同源。
    private var phaseText: String {
        ComposerStripModel.network(phase: phase, carrier: nil).text
    }

    private var nodeText: String {
        switch nodeState {
        case .noKey: return "未配置"
        case .registering: return "注册中"
        case .running: return "已入虚拟网"
        case .failed(.badKey): return "密钥无效或过期"
        case .failed(.unreachable): return "组网服务不可达"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary)
        }
        .font(.footnote)
    }
}

import SwiftUI

/// 一张待批审批卡（M5）。
///
/// 展示 `toolName` 与提问方的 `reason`，给两个一次性按钮。状态流转都写在
/// `ApprovalStore` 里 —— 这个视图只画：没动过给按钮，未知态如实说明，
/// 已投递就只等结果。**本视图绝不展示工具参数**：那是登记在 §8.5 的优化点，
/// 与参照实例（Web UI 的审批交互）同水位即可。
struct ApprovalCard: View {
    let approval: ApprovalStore.PendingApproval
    let state: ApprovalStore.AnswerState?
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("DSH 请求批准", systemImage: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Text(approval.toolName)
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)

            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            switch state {
            case .unknown:
                Text("已发出，结果未知 —— 等待 Mac 端回执，或重新打开本会话。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            default:
                HStack(spacing: 12) {
                    Button {
                        onAnswer(true)
                    } label: {
                        Text("允许一次")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onAnswer(false)
                    } label: {
                        Text("拒绝")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .listRowSeparator(.hidden)
    }
}

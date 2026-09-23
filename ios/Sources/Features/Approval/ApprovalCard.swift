import SwiftUI

/// 一张待批审批卡（M5）。
///
/// 展示 `toolName` 与 `reason`，给两个一次性按钮；状态流转都在 `ApprovalStore` 里，这个视图
/// 只画（没动过给按钮、未知态如实说明、已投递只等结果）。**绝不展示工具参数**：那是 §8.5 的
/// 优化点，与 Web UI 同水位即可。
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

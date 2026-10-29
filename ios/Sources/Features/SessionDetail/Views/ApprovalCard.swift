import SwiftUI

/// 一张待批审批卡。
/// 展示 `toolName` 与 `reason`，给两个一次性按钮；状态流转在 `ApprovalStore` 里。
struct ApprovalCard: View {
    let approval: ApprovalTable.Entry
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
            case .sending:
                Text(ApprovalStore.sendingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .unknown:
                Text(ApprovalStore.unknownNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .refused(let reason):
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case nil:
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
    }
}

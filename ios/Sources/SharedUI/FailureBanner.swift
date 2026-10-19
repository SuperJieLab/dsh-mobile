/**
 * 把失败原因摊在屏幕上。服务端的拒绝与网络层的失败都显示成**原文** ——
 * 它的价值有一半在「看得见为什么不行」。
 *
 * 被两个界面消费（会话列表、配对），所以住这儿而不是某个界面的 `Views/` ——
 * 判据在 `tests/LayeringTests.swift`：界面 `Views/` 下的类型不得被别的界面引用。
 */
import SwiftUI

struct FailureBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

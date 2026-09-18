import SwiftUI

/// 单个会话的消息视图。
///
/// 拉一次 `snapshot`（`since = 0`，全量），把能显示成消息的事件画成气泡。
/// 其余事件（工具调用、轮次边界、用量、审批……）不进对话流 ——
/// 它们属于「过程」，而这个屏要回答的是「这个会话聊了什么」。
struct SessionDetailView: View {
    let client: GatewayClient
    let session: SessionSummary

    @State private var snapshot: SessionSnapshot?
    @State private var failure: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let failure {
                Section {
                    FailureBanner(text: failure)
                }
            }

            if let snapshot {
                if snapshot.messages.isEmpty && failure == nil {
                    Text("这个会话里没有可显示的消息。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.messages) { message in
                    MessageBubble(message: message)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("共 \(snapshot.events.count) 条事件，其中 \(snapshot.messages.count) 条消息 · asOfSeq = \(snapshot.asOfSeq)")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(session.title ?? session.id)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && snapshot == nil {
                ProgressView("正在拉取快照…")
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // M1 恒传 0（全量）。差量要等 M2 的客户端状态机 —— 服务端已经支持 `since`。
            snapshot = try await client.snapshot(sessionId: session.id, since: 0)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// 一条消息气泡。
private struct MessageBubble: View {
    let message: DisplayMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(isUser ? "你" : "DSH")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isUser ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                    in: .rect(cornerRadius: 14)
                )
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
    }
}

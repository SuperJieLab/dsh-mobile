import SwiftUI

/// 会话列表 —— M1 客户端的第一个屏。
///
/// 它只做一件事：调 `list-sessions` 并把结果画出来。
/// 按协议，**排序是服务端的承诺**，所以这里一行排序代码都没有。
struct SessionListView: View {
    let client: GatewayClient

    @State private var sessions: [SessionSummary] = []
    @State private var failure: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let failure {
                Section {
                    FailureBanner(text: failure)
                }
            }

            ForEach(sessions) { session in
                NavigationLink(value: session) {
                    SessionRow(session: session)
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("\(sessions.count) 个会话 · \(client.baseURL.absoluteString)")
            }
        }
        .navigationTitle("会话")
        .navigationDestination(for: SessionSummary.self) { session in
            SessionDetailView(client: client, session: session)
        }
        .overlay {
            if isLoading && sessions.isEmpty {
                ProgressView("正在读 Mac 上的会话…")
            } else if sessions.isEmpty && failure == nil {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "tray",
                    description: Text("在 Mac 上的 DSH Web UI 里聊一句，这里就会出现。")
                )
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await client.listSessions()
            failure = nil
        } catch {
            // 失败时**不清空**已有列表：能显示多少显示多少，错误挂在上面。
            failure = error.localizedDescription
        }
    }
}

/// 列表里的一行。
private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title ?? "（无标题）")
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(relativeTime(session.updatedAt))
                Text("·")
                Text("\(session.eventCount) 条事件")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 把失败原因摊在屏幕上。
///
/// 刻意把服务端的拒绝与网络层的失败都显示成**原文**：M1 的价值有一半在
/// 「看得见为什么不行」，把它藏成一句「加载失败」就白做了。
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

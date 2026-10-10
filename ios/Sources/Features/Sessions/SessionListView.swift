import SwiftUI

/// 会话列表。它做两件事：调 `list-sessions`、按本屏的规则决定显示哪些行。按协议
/// **排序是服务端的承诺**（这里一行排序代码都没有），而「显示哪些」是客户端的事，故过滤在此。
struct SessionListView: View {
    /// `@ObservedObject`：`isPaired` 是可变共享状态 —— 被撤销时这一屏要立刻让位给配对屏。
    @ObservedObject var client: GatewayClient

    @State private var sessions: [SessionSummary] = []
    @State private var failure: String?
    @State private var isLoading = false
    /// 组网/配对入口：已配对时配对页不再自动顶上（凭证在同一次安装内持久），
    /// 组网段必须有常驻入口 —— 否则 noKey 状态无 UI 可达。
    @State private var showMeshSettings = false
    /// 回前台立即刷新：App 生命周期与列表域的连接点。
    @Environment(\.scenePhase) private var scenePhase
    /// 组网节点：连接方式一行的数据源（根部 environmentObject 注入）。
    @EnvironmentObject private var node: TailnetNode

    var body: some View {
        if !client.isPaired {
            PairingView(client: client)
        } else {
            pairedList
        }
    }

    private var pairedList: some View {
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
            // 显式再注一次（双保险）：navigationDestination 闭包在容器懒建时求值，
            // 根部注入被吞的场景下这里兜底（真机踩过：配对成功后进详情页崩溃）。
            SessionDetailView(client: client, session: session)
                .environmentObject(node)
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
        // 回前台立即刷新 —— 上游「恢复立即试」在列表域的对应。失败时旧列表照常保留。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await reload() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionBadge(state: ConnectionBadge.Status(isLoading: isLoading, lastFailure: failure),
                                meshPath: node.meshPath.map(ConnectionBadge.MeshPath.init))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMeshSettings = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .sheet(isPresented: $showMeshSettings) {
            NavigationStack { PairingView(client: client) }
                .environmentObject(node)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // 服务端给出事实（`blank` / `origin`），**显示哪些是客户端的事**，故过滤在此：`blank`
            // 点进去只有策略事件；`subagent` 是别的会话的子会话，不是独立对话。（与上游可见性规则
            // 同源；服务端另有「没有 cwd 的会话不列」，在适配器里。）
            sessions = try await client.listSessions()
                .filter { !$0.blank && $0.origin != "subagent" }
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
            HStack(spacing: 6) {
                Text(session.title ?? "（无标题）")
                    .font(.headline)
                    .lineLimit(2)

                if session.running {
                    Text("进行中")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }

            HStack(spacing: 6) {
                Text(relativeTime(session.updatedAt))
                Text("·")
                // 这一栏说的是「你上次发言」，不是「它上次动过」—— 协议 v2 起如此。
                Text("最后发言")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 把失败原因摊在屏幕上。服务端的拒绝与网络层的失败都显示成**原文** ——
/// 它的价值有一半在「看得见为什么不行」。
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

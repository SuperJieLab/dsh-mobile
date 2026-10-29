import SwiftUI

/// 会话列表 —— **全应用的首屏**。取数与「显示哪些」在 `SessionListState`；本文件只画，
/// 加四个触发点（下拉、回前台、组网就绪、工具栏按钮）—— 那是平台事件与用户手势。
/// **它永远是根**：前置条件不满足时不换屏，只在顶部给一条提示。
struct SessionListView: View {
    let list: SessionListState
    /// `phase` 驱动「就绪即首载」，`meshPath` 给徽章，`route` 给页脚地址。
    let store: MeshStore

    /// 回前台立即刷新：App 生命周期与列表域的连接点。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        pairedList
    }

    private var pairedList: some View {
        List {
            // 前置不满足时那条提示：中性，说的是「现在缺什么」—— 原文来自服务端那次失败。
            // 它不是错误面（红色那条在下面），因为用户没有做错任何事。
            if case .blocked(let reason) = list.outcome {
                Section {
                    Label(reason, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let failure = list.failureText {
                Section {
                    FailureBanner(text: failure)
                }
            }

            ForEach(list.sessions) { session in
                NavigationLink(value: Destination.session(session)) {
                    SessionRow(session: session)
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("\(list.sessions.count) 个会话 · \(gatewayAddressLine(store.route?.baseURL))")
            }
        }
        .navigationTitle("会话")
        .overlay {
            if list.isLoading && list.sessions.isEmpty {
                ProgressView("正在读 Mac 上的会话…")
            } else if list.sessions.isEmpty
                        && list.failureText == nil && list.blockedReason == nil {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "tray",
                    description: Text("在 Mac 上的 DSH Web UI 里聊一句，这里就会出现。")
                )
            }
        }
        .refreshable { await list.reload() }
        // 进屏首载。事件订阅不在这里：那是造这个 state 的装配段接的线（见
        // `SessionListAssembler`）。本屏只负责「什么时候取」——那是手势与平台事件。
        .task { await list.reload() }
        // 组网就绪即首载：启动窗口内的请求会 fail-fast（隧道产物还不存在），
        // 就绪那一刻补一发，用户不必手动下拉。reload 幂等，重复触发无害。
        // 这里的 `guard case .ready` 只是省一次必然失败的请求；「未就绪」该怎么显示由
        // `SessionListState` 的提示面决定。
        .onChange(of: store.phase) { _, phase in
            guard case .ready = phase else { return }
            Task { await list.reload() }
        }
        // 回前台立即刷新 —— 上游「恢复立即试」在列表域的对应。失败时旧列表照常保留。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await list.reload() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // 只喂 `failureText`：`.blocked` 时它是 nil，于是「还差一步配置」不会显示
                // 成「已断开」—— 网络本身可能好好的。
                ConnectionBadge(state: ConnectionBadge.Status(isLoading: list.isLoading,
                                                             lastFailure: list.failureText),
                                meshPath: store.meshPath)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 设置是唯一常驻入口：组网与身份两条都在里面。**它永远在** ——
                // 前置条件不满足时，用户要修的东西就在那里。
                NavigationLink(value: Destination.settings) {
                    Image(systemName: "gearshape")
                }
                Button {
                    Task { await list.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(list.isLoading)
            }
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

                // 列表不显示任何审批痕迹：有东西等你批时，只有点进那个会话才看得到
                // —— 与 Web UI 一致（它也不在列表渲染 `pendingInteraction`）。
                if session.running {
                    Text("进行中")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .fixedSize()
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

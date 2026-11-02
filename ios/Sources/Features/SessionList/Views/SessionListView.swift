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

    /// 新建一个空会话，建成就进去。
    ///
    /// 失败时**留在此屏**：`list.createSession()` 已经把说法落到列表顶部那一面。
    /// 不在这里再画一遍 —— 同一句话两处渲染，两处迟早不一致。
    private func newSession() {
        Task { await list.createSession() }
    }

    /// 这一屏的分组。每次渲染现算：行与组清单是两份事实，缓存分组会多出两份真相
    /// （行变了要重算、清单变了要重算，漏一处的症状是某个会话停在旧组里）。
    private var groups: [SessionGroup] {
        SessionGrouping.groups(sessions: list.sessions, workspaces: list.workspaces)
    }

    /// 组标题。未分组的组由界面给文案（判定层不放用户可见的中文）。
    private func title(of group: SessionGroup) -> String {
        if group.isUngrouped { return "未分组" }
        let title = group.title ?? ""
        return title.isEmpty ? "（未命名工作空间）" : title
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

            ForEach(groups) { group in
                Section {
                    ForEach(group.sessions) { session in
                        NavigationLink(value: Destination.session(sessionId: session.id, title: session.title)) {
                            SessionRow(session: session)
                        }
                    }
                } header: {
                    Text(title(of: group))
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
            if list.isLoading && groups.isEmpty {
                ProgressView("正在读 Mac 上的会话…")
            } else if groups.isEmpty
                        && list.failureText == nil && list.blockedReason == nil {
                ContentUnavailableView {
                    Label("还没有会话", systemImage: "tray")
                } description: {
                    // 空会话在发出第一条消息之前不进这个列表（那是「候选新会话」的定义）——
                    // 所以这句话说「第一条消息之后」，而不是「新建之后」。
                    Text("新建一个开始对话。发出第一条消息之后，它会出现在这里。")
                } actions: {
                    Button("新建会话") { newSession() }
                        .disabled(list.isCreating)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(list.isCreating)
                .accessibilityLabel("新建会话")
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

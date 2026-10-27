import SwiftUI

/// 会话列表。取数与「显示哪些」在 `SessionListState` 里；本文件只画，以及登记四个触发点
/// （下拉、回前台、组网就绪、工具栏按钮）—— 触发点是平台事件与用户手势，只有视图拿得到。
/// 进屏首载在本文件（平台事件）；事件订阅的接线在根部（它造这个 state，也就由它接）。
/// 按协议**排序是服务端的承诺**（这里一行排序代码都没有）。
///
/// 依赖全部在签名上，没有第二个通道：列表状态、连接域的只读投影、设置页的依赖面、页脚那句
/// 地址。`makeDetail` 与 `address` 是**能力**不是依赖对象 —— 前者的入参只有点开那一行才知道，
/// 后者只需一句字，本层因此不认识通信域。
struct SessionListView: View {
    let list: SessionListState
    /// 连接域的只读投影：`phase` 驱动「就绪即首载」，`meshPath` 给徽章。
    let store: MeshStore
    /// 设置页的依赖面 —— 工具栏齿轮推它。
    let settings: SettingsState
    /// 页脚那句地址。给的是**读串的能力**，不是端点对象。
    let address: () -> String
    /// 造下一屏的容器 —— 本屏只转交这个能力。
    let makeDetail: (SessionSummary) -> SessionDetailState

    /// 回前台立即刷新：App 生命周期与列表域的连接点。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        pairedList
    }

    private var pairedList: some View {
        List {
            if let failure = list.failureText {
                Section {
                    FailureBanner(text: failure)
                }
            } else if list.outcome == .waitingForMesh {
                Section {
                    // 组网就绪前的必然等待：不是错误，中性显示。
                    Label("等待组网就绪…", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(list.sessions) { session in
                NavigationLink(value: session) {
                    SessionRow(session: session)
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("\(list.sessions.count) 个会话 · \(address())")
            }
        }
        .navigationTitle("会话")
        .navigationDestination(for: SessionSummary.self) { session in
            SessionDetailView(session: session, make: makeDetail)
        }
        .overlay {
            if list.isLoading && list.sessions.isEmpty {
                ProgressView("正在读 Mac 上的会话…")
            } else if list.sessions.isEmpty && list.failureText == nil {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "tray",
                    description: Text("在 Mac 上的 DSH Web UI 里聊一句，这里就会出现。")
                )
            }
        }
        .refreshable { await list.reload() }
        // 进屏首载。事件订阅不在这里：它是 App 级的一次接线，挂在组合根上（那边造
        // 这个 state，也就由它接）。本屏只负责「什么时候取」——那是手势与平台事件。
        .task { await list.reload() }
        // 组网就绪即首载：启动窗口内的请求会 fail-fast（端点还不存在），
        // 就绪那一刻补一发，用户不必手动下拉。reload 幂等，重复触发无害。
        // 这里的 `guard case .ready` 只是省一次必然失败的请求；「未就绪」该怎么显示由
        // `SessionListState` 的等待面决定（与详情屏同一形状，见 SessionDetailView）。
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
                ConnectionBadge(state: ConnectionBadge.Status(isLoading: list.isLoading,
                                                             lastFailure: list.failureText),
                                meshPath: store.meshPath)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 设置是唯一常驻入口：组网与身份两行都在里面。未就绪时界面本身就是组网
                // 配置页，不必从这里进。
                NavigationLink {
                    SettingsView(state: settings)
                } label: {
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

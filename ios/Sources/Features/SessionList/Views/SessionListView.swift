import SwiftUI

/// 会话列表。取数与「显示哪些」在 `SessionListState` 里；本文件只画，以及登记五个触发点
/// （进屏、下拉、回前台、组网就绪、工具栏按钮）—— 触发点是平台事件与用户手势，只有视图拿得到。
/// 按协议**排序是服务端的承诺**（这里一行排序代码都没有）。
struct SessionListView: View {
    /// 读它是为了渲染：`isPaired` 决定这一屏让位给配对屏，`baseURL` 显示在页脚。
    /// 取数走 `state`，不经这里。
    @ObservedObject var client: GatewayClient
    /// 到网关的常驻连接（App 级）。本屏只用它传给会话详情 —— 连接不随哪一屏生死。
    let link: GatewayLink
    /// 连接级事件流。列表是它的消费方之一：逐个事件改一行，代次报到就重拉一次。
    let events: ConnectionEvents

    /// 取数与三种面。`@StateObject`：视图重建时保留，不随 body 重算重建。
    @StateObject private var state: SessionListState

    /// 组网/配对入口：已配对时配对页不再自动顶上（凭证在同一次安装内持久），
    /// 组网段必须有常驻入口 —— 否则 noKey 状态无 UI 可达。
    @State private var showMeshSettings = false
    /// 回前台立即刷新：App 生命周期与列表域的连接点。
    @Environment(\.scenePhase) private var scenePhase
    /// 根部注入的连接域：就绪即首载与徽章的路径一行都读它。
    @EnvironmentObject private var store: ConnectionStore
    /// 根部注入的待答表：每一行问它「本会话还挂着几条」。只读，不发请求。
    @EnvironmentObject private var approvals: ApprovalStore

    init(client: GatewayClient, link: GatewayLink, events: ConnectionEvents) {
        self.client = client
        self.link = link
        self.events = events
        _state = StateObject(wrappedValue: SessionListState(client: client))
    }

    var body: some View {
        if !client.isPaired {
            PairingView(client: client)
        } else {
            pairedList
        }
    }

    private var pairedList: some View {
        List {
            if let failure = state.failureText {
                Section {
                    FailureBanner(text: failure)
                }
            } else if state.outcome == .waitingForMesh {
                Section {
                    // 组网就绪前的必然等待：不是错误，中性显示。
                    Label("等待组网就绪…", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(state.sessions) { session in
                NavigationLink(value: session) {
                    // 计数现取：表是唯一来源，不为它备一份镜像（两份事实就有谁先更新的问题）。
                    SessionRow(session: session,
                               pendingCount: approvals.pendingCount(in: session.id))
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("\(state.sessions.count) 个会话 · \(client.baseURL?.absoluteString ?? "未激活")")
            }
        }
        .navigationTitle("会话")
        .navigationDestination(for: SessionSummary.self) { session in
            // 显式再注一次（双保险）：navigationDestination 闭包在容器懒建时求值，
            // 根部注入到不了推入的视图 —— 不补这一句，详情页读不到连接域。
            SessionDetailView(client: client, session: session, link: link)
                .environmentObject(store)
        }
        .overlay {
            if state.isLoading && state.sessions.isEmpty {
                ProgressView("正在读 Mac 上的会话…")
            } else if state.sessions.isEmpty && state.failureText == nil {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "tray",
                    description: Text("在 Mac 上的 DSH Web UI 里聊一句，这里就会出现。")
                )
            }
        }
        .refreshable { await state.reload() }
        // 一个 task、一条语句序：先订阅再首载。两个 `.task` 之间没有执行顺序的承诺，
        // 而「订阅之前到达的那一帧」不会进账（那时没有在途请求可归）。
        // `attach` 幂等，视图重复出现不会注册第二个听众。
        .task {
            state.attach(events: events)
            await state.reload()
        }
        // 组网就绪即首载：启动窗口内的请求会 fail-fast（端点还不存在），
        // 就绪那一刻补一发，用户不必手动下拉。reload 幂等，重复触发无害。
        // 这里的 `guard case .ready` 只是省一次必然失败的请求；「未就绪」该怎么显示由
        // `SessionListState` 的等待面决定（与详情屏同一形状，见 SessionDetailView）。
        .onChange(of: store.phase) { _, phase in
            guard case .ready = phase else { return }
            Task { await state.reload() }
        }
        // 回前台立即刷新 —— 上游「恢复立即试」在列表域的对应。失败时旧列表照常保留。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await state.reload() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionBadge(state: ConnectionBadge.Status(isLoading: state.isLoading,
                                                             lastFailure: state.failureText),
                                meshPath: store.meshPath)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showMeshSettings = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                Button {
                    Task { await state.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(state.isLoading)
            }
        }
        .sheet(isPresented: $showMeshSettings) {
            NavigationStack { PairingView(client: client) }
                .environmentObject(store)
        }
    }
}

/// 列表里的一行。
private struct SessionRow: View {
    let session: SessionSummary
    /// 本会话还挂着的审批条数（来自 App 级的那张待答表）。
    let pendingCount: Int

    /// 这一行该画哪几枚标签 —— 排序与文字都在 `SessionRowChip` 里，这里不拼条件。
    private var chips: [SessionRowChip] {
        SessionRowChip.of(running: session.running, pendingCount: pendingCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.title ?? "（无标题）")
                    .font(.headline)
                    .lineLimit(2)

                // 两件事不同（在做 / 等你），所以并列、各自着色，谁也不顶掉谁。
                ForEach(chips, id: \.self) { chip in
                    Text(chip.text)
                        .font(.caption2)
                        .foregroundStyle(tint(for: chip))
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

    private func tint(for chip: SessionRowChip) -> Color {
        switch chip {
        case .running: return .accentColor
        case .pending: return .orange
        }
    }
}

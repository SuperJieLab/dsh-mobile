import SwiftUI

/// 单个会话的消息视图。
///
/// 数据来自 `SessionSync` —— 它负责「先取一个窗口、再往后追新增、按需往回翻」，这个屏只管
/// 画出来，以及把同步状态如实显示在底部。**往回翻是显式的**（列表第一行那个入口）：只在
/// 用户要的时候才拉，不偷偷多拉一批；`hasOlder` 由服务端给，客户端不自己猜。
///
/// 对话流 = 消息气泡 + **折起的过程行**（工具调用与轮次边界进流，默认收起成一行摘要，
/// 点开才是工具行与思考行）；流式输出、占位行与审批卡另占各自的位置。
struct SessionDetailView: View {
    let client: GatewayClient
    let session: SessionSummary

    /// 同步编排。视图重建时会新建一个、窗口重取一次 —— 重取的理由见 `SessionSync`。
    @StateObject private var sync: SessionSync

    /// 是否已经做过「首次定位到最新」。之后的内容变化（往回翻的前插）不再抢视口。
    @State private var didInitialScroll = false
    /// 输入框里的草稿（下发指令）。
    @State private var draft = ""
    /// 回前台立即重连：App 生命周期与详情域的连接点。
    @Environment(\.scenePhase) private var scenePhase
    /// 连接域：连接方式一行的数据源（根部 environmentObject 注入，R3 起唯一出处）。
    @EnvironmentObject private var store: ConnectionStore

    init(client: GatewayClient, session: SessionSummary) {
        self.client = client
        self.session = session
        _sync = StateObject(wrappedValue: SessionSync(client: client, sessionId: session.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if sync.hasOlder {
                    Button {
                        Task { await sync.loadOlder() }
                    } label: {
                        HStack {
                            Spacer()
                            if sync.status == .syncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("加载更早的消息")
                            }
                            Spacer()
                        }
                    }
                    .disabled(sync.status == .syncing)
                    .listRowSeparator(.hidden)
                }

                if sync.eventCount > 0 && sync.nodes.isEmpty {
                    Text("这个会话里没有可显示的内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(sync.nodes) { node in
                    switch node {
                    case .message(let message):
                        MessageBubble(message: message)
                    case .process(let process):
                        // 一轮的过程：它不是「消息」，所以不套气泡 —— 视觉上要与对话区分开。
                        TurnProcessRow(process: process)
                            .listRowSeparator(.hidden)
                    }
                }

                // 流式输出：正在生成的回复。它不在镜像里 —— 未定稿内容没有 seq，不属于「已读到的
                // 位置」（镜像的第一条纪律）。它逐 chunk 增长，源文变化时 `MarkdownText` 只重
                // 解析尾部、已渲染的块原样留着。
                if !sync.transientText.isEmpty {
                    Text("DSH 正在输入…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    MarkdownText(source: sync.transientText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                }

                // 滚动锚点：初始同步完成后定位到这里（最新的消息在列表末尾）。
                Color.clear
                    .frame(height: 1)
                    .listRowSeparator(.hidden)
                    .id(Self.bottomAnchor)

                Section {
                    EmptyView()
                } footer: {
                    Text("共 \(sync.eventCount) 条事件，其中 \(sync.messages.count) 条消息 · \(sync.status.line)")
                }
            }
            .listStyle(.plain)
            // 打开会话 = 停在最新的消息上（对话的阅读方向），而不是列表的开头。
            .defaultScrollAnchor(.bottom)
            .onChange(of: sync.nodes.count) { _, count in
                // 只在**首次**有内容时滚一次：往回翻（前插）不能把用户的视口拽走。
                guard !didInitialScroll, count > 0 else { return }
                didInitialScroll = true
                withAnimation {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .overlay {
                if sync.status == .idle && sync.eventCount == 0 {
                    ProgressView("正在同步…")
                }
            }
            .refreshable { await sync.sync() }
            // 进屏即订阅：opening 给首屏，事件与未定稿实时推。
            // 离屏即停。`sync()`（HTTP 全量对齐）保留给下拉刷新作兜底。
            .task { sync.startFollowing() }
            .onDisappear { sync.stopFollowing() }
            // 组网就绪即重连（R5 修正 4①，与列表「就绪即首载」对称）：connecting 期间
            // 进页时 WS 在退避循环里空转（端点不存在），就绪此刻不等下一轮退避。
            .onChange(of: store.phase) { _, phase in
                guard case .ready = phase else { return }
                sync.reconnectNow()
            }
            // 回前台立即重连 —— 上游「恢复立即试」在详情域的对应。
            // 已就绪 / 正在握手时 reconnectNow() 自己无事发生，不会叠加连接。
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                sync.reconnectNow()
            }
            .safeAreaInset(edge: .bottom) {
                // 底栏：审批卡 → 说明行 → 输入框 → 连接态。审批面板挂在 composer 上方是
                // 上游的原生位置（conversation.composer 槽位）——「正在问我的事」永远在输入框旁。
                VStack(spacing: 0) {
                    ForEach(sync.approvals.pending) { approval in
                        ApprovalCard(approval: approval, state: sync.approvals.states[approval.id]) { allow in
                            Task { await sync.approvals.answer(approval, allow: allow) }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }

                    if let notice = sync.approvals.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    }

                    // 上下文占用：上游把它放在 composer 旁，这里同位置；
                    // 没有读数就整行不出现。
                    if let usage = sync.usage {
                        OccupancyBar(usage: usage)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }

                    HStack(spacing: 8) {
                        // 当前模型：选择器住在发送区旁（上游 composer 槽位），不占消息流。
                        ModelPickerView(sync: sync)
                        TextField("发一条指令给 DSH…", text: $draft, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let text = draft
                            draft = ""
                            Task { await sync.sendPrompt(text) }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    // 「内容没能接上 / 已被清空重来」的告知（R10 期2 链路 C）。它挂在**不随内容
                    // 滚动**的底栏里 —— 同步状态行那句在 List 的 footer（跟着内容一起滚），用户
                    // 往回翻时正好看不见，而那正是最需要看见的时候。非模态、不需用户点掉，
                    // 一直显示到重新建立（判定在 `SessionSync`，这里只画）。
                    if let notice = sync.notice {
                        Label {
                            Text(notice.line)
                        } icon: {
                            Image(systemName: notice.kind == .reset
                                  ? "arrow.counterclockwise.circle"
                                  : "exclamationmark.triangle")
                        }
                        .font(.footnote)
                        .foregroundStyle(notice.kind == .reset ? Color.red : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                    }

                    // 连接态指示器：订阅流断开时如实说「已断开」，旧内容照常可读。
                    ConnectionBadge(state: ConnectionBadge.Status(followPhase: sync.connectionPhase),
                                    meshPath: store.meshPath.map(ConnectionBadge.MeshPath.init))
                        .padding(.vertical, 4)
                }
                .background(.bar)
            }
        }
    }

    /// 底部滚动锚点的 id。
    private static let bottomAnchor = "session-detail-bottom"
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

            // 助手的话按 Markdown 排版（块级自己画、行内交给系统）；用户输入是纯文本，
            // 不值得解一遍。
            Group {
                if isUser {
                    Text(message.text)
                } else {
                    MarkdownText(source: message.text)
                }
            }
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

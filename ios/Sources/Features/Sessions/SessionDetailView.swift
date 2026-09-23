import SwiftUI

/// 单个会话的消息视图。
///
/// 数据来自 `SessionSync` —— 它负责「先取一个窗口、再往后追新增、按需往回翻」，
/// 这个屏只负责画出来，以及把同步状态如实显示在底部。
///
/// **往回翻是显式的**（列表第一行那个入口）：历史只在用户要的时候才拉，而不是偷偷
/// 多拉一批。`hasOlder` 由服务端给，客户端不自己猜还有没有。
///
/// 对话流 = 消息气泡 + **折起的过程行**（M6 起工具调用与轮次边界进流，但默认收起成
/// 一行摘要，点开才是工具行与思考行）；打字机、占位行与审批卡另占各自的位置。
struct SessionDetailView: View {
    let client: GatewayClient
    let session: SessionSummary

    /// 同步编排。视图重建时会新建一个，于是窗口重取一次 —— 这是刻意的：
    /// 窗口是服务端此刻给的，比任何本地残留都可信（见 `SessionMirror` 的说明）。
    @StateObject private var sync: SessionSync

    /// 是否已经做过「首次定位到最新」。之后的内容变化（往回翻的前插）不再抢视口。
    @State private var didInitialScroll = false
    /// 输入框里的草稿（M5 下发指令）。
    @State private var draft = ""
    /// 回前台立即重连（M3）：App 生命周期与详情域的连接点。
    @Environment(\.scenePhase) private var scenePhase

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
                        // 一轮的过程：默认收起成一行摘要，点开是工具行与思考行。
                        // 它不是「消息」，所以不套气泡 —— 视觉上要和对话区分开。
                        TurnProcessRow(process: process)
                            .listRowSeparator(.hidden)
                    }
                }

                // 打字机：正在生成的回复。它不在镜像里 —— 瞬态内容没有 seq，
                // 不属于「已读到的位置」（M2 的第一条纪律）。
                //
                // 它逐 chunk 增长，所以这里正是「尾部冻结」的用武之地：源文变化时
                // `MarkdownText` 只重解析尾部，已渲染的那几块原样留着（判据 M3）。
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
            // 进屏即跟随（M2 主路径）：opening 给首屏，事件与瞬态实时推。
            // 离屏即停。`sync()`（HTTP 全量对齐）保留给下拉刷新作兜底。
            .task { sync.startFollowing() }
            .onDisappear { sync.stopFollowing() }
            // 回前台立即重连 —— 上游「恢复立即试」在详情域的对应（M3）。
            // 已就绪 / 正在握手时 reconnectNow() 自己无事发生，不会叠加连接。
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                sync.reconnectNow()
            }
            .safeAreaInset(edge: .bottom) {
                // 底栏：审批卡（M5）→ 说明行 → 输入框 → 连接态。审批面板挂
                // composer 上方是上游 Web UI 的原生位置（conversation.composer
                // 槽位）——「正在问我的事」永远在输入框旁边，不在消息流里。
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

                    // 上下文占用（M6）：上游把它放在 composer 旁，这里同位置。
                    // 没有读数就整行不出现 —— 不画一个 0%（与判据 U2 同一条纪律：
                    // 「不知道」不该被显示成「空」）。
                    if let usage = sync.usage {
                        OccupancyBar(usage: usage)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }

                    HStack(spacing: 8) {
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

                    // 连接态指示器：跟随流断开时如实说「已断开」，旧内容照常可读。
                    ConnectionBadge(state: ConnectionBadge.Status(followPhase: sync.connectionPhase))
                        .padding(.vertical, 4)
                }
                .background(.bar)
            }
        }
    }

    /// 底部滚动锚点的 id。`private` 的静态值即可 —— 只有这个视图需要它。
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

            // 助手的话按 Markdown 排版（标题 / 列表 / 代码块 / 引用 / 分隔线由块级自己画，
            // 行内交给系统）；用户输入是纯文本，不值得解一遍。M6 步骤 5。
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

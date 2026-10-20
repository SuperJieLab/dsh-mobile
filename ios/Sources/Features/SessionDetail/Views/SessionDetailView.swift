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
    /// 模型目录。宿主持有：功能条那一格要用目录默认值兜底显示名，两处读的必须是同一份。
    @StateObject private var catalog: ModelCatalogState

    /// 是否已经做过「首次定位到最新」。之后的内容变化（往回翻的前插）不再抢视口。
    @State private var didInitialScroll = false
    /// 输入框里的草稿（下发指令）。
    @State private var draft = ""
    /// 本屏四个展开面。共用一个 `.sheet(item:)` 的理由见 `body` 里那段注释。
    @State private var activeSheet: DetailSheet?
    /// 输入框有没有焦点：打字时功能条收起，把高度让给内容与键盘。
    @FocusState private var isComposing: Bool
    /// 回前台立即重连：App 生命周期与详情域的连接点。
    @Environment(\.scenePhase) private var scenePhase
    /// 根部注入的连接域：功能条的网络格、连接详情与「就绪即重连」都读它。
    @EnvironmentObject private var store: ConnectionStore

    init(client: GatewayClient, session: SessionSummary) {
        self.client = client
        self.session = session
        _sync = StateObject(wrappedValue: SessionSync(client: client, sessionId: session.id))
        _catalog = StateObject(
            wrappedValue: ModelCatalogState { try await client.modelCatalog() }
        )
    }

    var body: some View {
        Group {
            if sync.eventCount == 0 {
                // 内容还没到：**不挂 List**。空列表先出现、再一次性插入几十行，会让列表
                // 在顶部完成初始布局；随后任何补滚都是一次看得见的位移 —— 那就是
                // 「刷新出来、再滚下去」的来源。列表等有内容再创建，首次布局就在底部。
                //
                // 这一屏必须自己撑满：`safeAreaInset` 的底栏贴在被修饰视图的**下边界**上，
                // 而 ProgressView 的固有高度只有一行 —— 不撑满时底栏会跟着浮到屏幕中间。
                ProgressView("正在同步…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
        }
        // 进屏即订阅：opening 给首屏，事件与未定稿实时推。
        // 离屏即停。`sync()`（HTTP 全量对齐）保留给下拉刷新作兜底。
        .task { sync.startFollowing() }
        // 目录进屏拉一次。挂在格子上的话，功能条每次因键盘收起而重建都会重拉一遍。
        .task { await catalog.reload() }
        .onDisappear { sync.stopFollowing() }
        // 组网就绪即重连（与列表「就绪即首载」对称）：connecting 期间
        // 进页时 WS 在退避循环里空转（端点不存在），就绪此刻不必再等下一轮退避。
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
            bottomBars
        }
        .navigationTitle(session.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        // 四个展开面共用一个 `.sheet(item:)`：两个独立的 `.sheet` 在同一事务里
        // 「关一个、开一个」（连接详情 → 组网设置）时，第二个经常不 present。
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .network:
                networkSheet
            case .usage:
                UsageSheet(usage: sync.usage)
            case .approvals:
                allApprovalsSheet
            case .mesh:
                NavigationStack {
                    PairingView(client: client)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { activeSheet = nil }
                            }
                        }
                }
                .environmentObject(store)
            }
        }
    }

    /// 有内容之后才挂的那一屏。**它的创建时机就是「一进去停在最底部」的判据**：
    /// 列表不在空状态下先出现，初始布局才有机会落在底部。
    private var transcript: some View {
        ScrollViewReader { proxy in
            List {
                if sync.hasOlder {
                    if sync.isPagingOlder {
                        // 等待期间给三行占位，而不是一个转圈：用户往上拉就是在找更早的内容，
                        // 一片空白加个小转圈会让人以为到头了。高度按一行消息估，替换时不跳。
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(uiColor: .secondarySystemBackground))
                                .frame(height: 44)
                                .padding(.vertical, 2)
                                .listRowSeparator(.hidden)
                        }
                    } else {
                        Button {
                            // 这里**不**做「插入后把视口锚回原来那条」。`scrollTo` 是强制拉位置，
                            // 而系统本来就会保持一部分偏移 —— 两者叠加是一次可见的跳，比不锚更糟。
                            // 前插造成的位移只能在「滚动已停」时才谈得上修正，而滚动状态在本机
                            // SDK 里拿不到（`onScrollPhaseChange` 那一族不在 interface 里）。
                            Task { await sync.loadOlder() }
                        } label: {
                            HStack {
                                Spacer()
                                Text("加载更早的消息")
                                Spacer()
                            }
                        }
                        .listRowSeparator(.hidden)
                    }
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
                    MarkdownText(source: sync.transientText, caching: false)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("共 \(sync.eventCount) 条事件，其中 \(sync.messages.count) 条消息 · \(sync.status.line)")
                }

                // 滚动锚点：**必须在 footer 之后**。`scrollTo(…, anchor: .bottom)` 对齐的是
                // 视口底部，锚点摆在 footer 之前时，那条说明会被挤出可视区 —— 进屏那一刻
                // 正好压在底栏后面，看起来像没滚到底。
                Color.clear
                    .frame(height: 1)
                    .listRowSeparator(.hidden)
                    .id(Self.bottomAnchor)
            }
            .listStyle(.plain)
            // 首次布局就锚在底部。列表是**有内容之后才创建**的，所以此刻它算「初始布局」。
            .defaultScrollAnchor(.bottom)
            // 往回翻是往**顶部**插行。这一次变化不走隐式动画 —— 一次插入几十行的布局动画
            // 在长会话上很贵，而用户并不需要看见内容「长出来」。`eventCount` 与内容同步变，
            // 用它当 key 能覆盖「插入了不产生节点的事件」这种情形。
            .animation(nil, value: sync.eventCount)
            .onAppear {
                // 与上面同一个目标：列表最末尾那行锚点。**无动画** —— 生效时等于原地不动，
                // 不生效时也只是瞬移，而不是用户能看见的「滚下去」。
                guard !didInitialScroll else { return }
                didInitialScroll = true
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .refreshable { await sync.sync() }
            // 打字时滚动列表即收键盘 —— 与配对屏同口径；这是功能条回来的唯一手势
            // （发送也会收，见 `composerRow`）。
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: - 底栏

    /// 底栏分三段，互不挤压 —— 输入框的位置只由键盘决定，不随连接态与待批卡上下跳。
    ///
    /// 上到下：审批卡（条件段）→ 告知（有事才出现）→ 功能条（打字时收起）→ 输入行。
    /// 功能条那 32pt 是常驻占用，换来一眼可见的连接态、模型与占用；键盘弹起时整条收起，
    /// 因为打字期间屏幕高度最紧张，而这三项读数在那时没有决策价值。
    private var bottomBars: some View {
        VStack(spacing: 0) {
            approvalSection

            if let notice = sync.notice {
                noticeRow(notice)
            }

            if !isComposing {
                ComposerStrip(
                    model: stripModel,
                    catalog: catalog,
                    selectedModel: sync.displayedModel,
                    onSelectModel: { selection in
                        Task { await sync.selectModel(selection) }
                    },
                    onTapNetwork: { activeSheet = .network },
                    onTapUsage: { activeSheet = .usage }
                )
            }

            composerRow
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        // 一整块玻璃：内容在里面，边界用圆角裁；外层再让出屏幕边距，于是它浮起来。
        .modifier(ComposerSurface())
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// 功能条三格的值 —— 从编排取数转成显示值的唯一一处。
    private var stripModel: ComposerStripModel {
        ComposerStripModel.make(
            phase: sync.connectionPhase,
            carrier: store.meshPath,
            usage: sync.usage,
            // 兜底规则：选中值 ?? 目录默认 ?? 未知。目录默认值只为「重拉期间不闪成未知」。
            modelName: (sync.displayedModel ?? catalog.lastKnownDefault).map { $0.model }
                ?? "未知"
        )
    }

    /// 待批卡：只露第一张，其余折成一行计数。
    ///
    /// 审批是串行的 —— 批完一张才该看下一张。同时露两张不提供额外判断信息，只会把输入框
    /// 再往上推 132pt，而那正是「挤」的主因。卡本身仍在输入框上方：它必须一眼看见。
    @ViewBuilder
    private var approvalSection: some View {
        if let first = sync.approvals.pending.first {
            ApprovalCard(approval: first, state: sync.approvals.states[first.id]) { allow in
                Task { await sync.approvals.answer(first, allow: allow) }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            if sync.approvals.pending.count > 1 {
                Button {
                    activeSheet = .approvals
                } label: {
                    Text("还有 \(sync.approvals.pending.count - 1) 个待批准")
                        .font(.footnote)
                }
                .padding(.bottom, 6)
            }
        }

        if let notice = sync.approvals.notice {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        }
    }

    /// 「内容没能接上 / 已被清空重来」的告知。它挂在**不随内容滚动**的底栏里 ——
    /// 同步状态行那句在 List 的 footer（跟着内容一起滚），用户往回翻时正好看不见，
    /// 而那正是最需要看见的时候。非模态、不需用户点掉，一直显示到重新建立。
    private func noticeRow(_ notice: ResyncNotice) -> some View {
        Label {
            Text(notice.line)
        } icon: {
            Image(systemName: look(of: notice).icon)
        }
        .font(.footnote)
        .foregroundStyle(look(of: notice).tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    /// 输入行：宽度全给输入框，发送键在最右。
    ///
    /// 输入框**不带自己的边框**：它坐在玻璃上，再加一圈描边就成了两层皮。
    private var composerRow: some View {
        HStack(spacing: 6) {
            TextField("发一条指令给 DSH…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .focused($isComposing)
            Button {
                let text = draft
                draft = ""
                // 发送即收键盘：功能条跟着回来，用户能看到它接下来的连接态与占用。
                isComposing = false
                Task { await sync.sendPrompt(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(PromptDraft.normalized(draft) == nil)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - 详情面

    private var networkSheet: some View {
        NetworkSheet(phase: sync.connectionPhase,
                     carrier: store.meshPath,
                     lastFrameAt: sync.lastFrameAt,
                     nodeState: store.nodeState,
                     configDamaged: store.storedConfigDamaged,
                     onRetry: { sync.reconnectNow() },
                     onOpenMesh: { activeSheet = .mesh })
    }

    /// 折叠起来的那些卡。**不含**上方已经露出的第一张 —— 文案说「还有 N 个」，列出来的就该是 N 个。
    private var allApprovalsSheet: some View {
        let rest = Array(sync.approvals.pending.dropFirst())
        return NavigationStack {
            Group {
                if rest.isEmpty {
                    ContentUnavailableView(
                        "没有更多待批准的请求",
                        systemImage: "checkmark.circle",
                        description: Text("新请求到达时会出现在这里。")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(rest) { approval in
                                ApprovalCard(approval: approval,
                                             state: sync.approvals.states[approval.id]) { allow in
                                    Task { await sync.approvals.answer(approval, allow: allow) }
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("待批准")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 本屏四个展开面。合成一个 `.sheet(item:)` 的 id。
    private enum DetailSheet: String, Identifiable {
        case network
        case usage
        case approvals
        case mesh

        var id: String { rawValue }
    }

    /// 底部滚动锚点的 id。
    private static let bottomAnchor = "session-detail-bottom"

    /// 告知那一行的图标与颜色 —— 逐 case 列举，`ResyncNotice.Kind` 加取值时编译失败。
    private func look(of notice: ResyncNotice) -> (icon: String, tint: Color) {
        switch notice.kind {
        case .unresolved:
            return ("exclamationmark.triangle", .orange)
        case .reset:
            return ("arrow.counterclockwise.circle", .red)
        }
    }
}

/// 底栏的材质：iOS 26 起用玻璃（Liquid Glass），以下退回 `.bar` 材质。
///
/// 抽成 modifier 而不是写在 `bottomBars` 里：availability 分支夹在 body 中间时，
/// 读者会以为两态的布局不同 —— 它们只是材质不同，内容与尺寸完全一致。
private struct ComposerSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 26))
        } else {
            content.background(.bar, in: .rect(cornerRadius: 26))
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

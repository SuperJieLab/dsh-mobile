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
    /// 命令目录。每次敲 `/` 都要一份新的 —— 命令集随插件装卸变，不缓存。
    @StateObject private var commands: CommandDirectory

    /// 是否已经做过「首次定位到最新」。之后的内容变化（往回翻的前插）不再抢视口。
    @State private var didInitialScroll = false
    /// 输入框那一行：草稿、能不能发、面板该不该开 —— 判定在 `State/ComposerState.swift`。
    @StateObject private var composer = ComposerState()
    /// 本屏五个展开面。共用一个 `.sheet(item:)` 的理由见 `body` 里那段注释。
    @State private var activeSheet: DetailSheet?
    /// 输入框有没有焦点：打字时功能条收起，把高度让给内容与键盘。
    @FocusState private var isComposing: Bool
    /// 根部注入的连接域：功能条的网络格与连接详情读它（图中转与节点状态）。
    @EnvironmentObject private var store: MeshStore
    /// 根部注入的待答表：App 级，不随本屏生死 —— 停在列表时到达的审批也在里面。
    @EnvironmentObject private var approvals: ApprovalStore

    /// - Parameter link: 只在这里交给 `SessionSync`，本视图不保留 —— 屏幕能对连接做的
    ///   只有流级动作（`SessionSync.retry()`），连接级动作在它的类型上不存在。
    init(client: GatewayClient, session: SessionSummary, link: GatewayHost) {
        self.client = client
        self.session = session
        _sync = StateObject(wrappedValue: SessionSync(client: client, sessionId: session.id, link: link))
        _catalog = StateObject(
            wrappedValue: ModelCatalogState { try await fetchCatalog(client) }
        )
        _commands = StateObject(
            wrappedValue: CommandDirectory { try await fetchCommands(client, sessionId: session.id) }
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
        // 进屏即登记一条流：opening 给首屏，事件与未定稿实时推。
        // 离屏即注销那一条。`sync()`（HTTP 全量对齐）只留作首屏兜底。
        //
        // 连接不归本屏：回前台与组网就绪的重连点在根部（`DshMobileApp`）—— 那是 App 级
        // 事件，关掉这一屏它照样该发生。
        .task { sync.startFollowing() }
        // 目录进屏拉一次。挂在格子上的话，功能条每次因键盘收起而重建都会重拉一遍。
        .task { await catalog.reload() }
        // 命令目录：**每次开始敲命令时重拉一次**（`onChange` 里判「刚进入 querying」）。
        // 挂在面板上会让每敲一个字都拉一遍；只在打开那一刻拉，刚好够用。
        .onChange(of: isCommandPaletteOpen) { _, open in
            guard open else { return }
            Task { await commands.reload() }
        }
        .onDisappear { sync.stopFollowing() }
        .safeAreaInset(edge: .bottom) {
            bottomBars
        }        .navigationTitle(session.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        // 五个展开面共用一个 `.sheet(item:)`：两个独立的 `.sheet` 在同一事务里
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
            case .model:
                ModelSheetView(
                    catalog: catalog,
                    selected: sync.displayedModel,
                    onSelect: { selection in Task { await sync.selectModel(selection) } },
                    onClose: { activeSheet = nil }
                )
            }
        }
    }

    /// 有内容之后才挂的那一屏。**它的创建时机就是「一进去停在最底部」的判据**：
    /// 列表不在空状态下先出现，初始布局才有机会落在底部。
    private var transcript: some View {
        ScrollViewReader { proxy in
            List {
                // 翻页是自动的（见 List 上的 `onScrollGeometryChange`），这里只画
                // 「正在拉」的占位。等待期间给三行骨架而不是转圈：用户往上拉就是在找更早的
                // 内容，一片空白加个小转圈会让人以为到头了。高度按一行消息估，替换时不跳。
                if sync.hasOlder && sync.isPagingOlder {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(uiColor: .secondarySystemBackground))
                            .frame(height: 44)
                            .padding(.vertical, 2)
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
                    case .command(let run):
                        // 命令也不是消息：一次动作，一行说清按了什么、结果如何。
                        CommandRow(run: run)
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
            // 滑到接近顶部就自动往回翻。只认**进入**边沿：前插之后内容总高变大、离顶更远，
            // 条件自然复位，用户继续往上滑才会触发下一次 —— 这就是分页的节奏，不会一口气拉完。
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top <= Self.topTriggerDistance
            } action: { wasNear, isNear in
                guard isNear, !wasNear, sync.hasOlder, !sync.isPagingOlder else { return }
                Task { await sync.loadOlder() }
            }
            .onAppear {
                // 与上面同一个目标：列表最末尾那行锚点。**无动画** —— 生效时等于原地不动，
                // 不生效时也只是瞬移，而不是用户能看见的「滚下去」。
                guard !didInitialScroll else { return }
                didInitialScroll = true
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            // 不用 `.refreshable`：它的语义是「拉最新」，却只能挂在列表**顶部** —— 而顶部
            // 该做的是往回翻历史，手势方向与内容方向正好相反。两头都交给上面那条
            // `onScrollGeometryChange`（顶部翻历史、底部对齐最新）。
            // 打字时滚动列表即收键盘 —— 与配对屏同口径；这是功能条回来的唯一手势
            // （发送也会收，见 `composerRow`）。
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: - 底栏

    /// 底栏分五段：审批卡（条件）→ 告知（有事才出现）→ 命令候选（在敲命令时）→ 功能条 → 输入行。
    ///
    /// 命令候选排在功能条之上、输入框紧邻：它是「当前这一行」的补充，离输入框越近越好；
    /// 功能条在打字时收起（原本就有），所以候选出现时那一行高度刚好让给它。
    private var bottomBars: some View {
        VStack(spacing: 0) {
            approvalSection

            if let notice = sync.notice {
                noticeRow(notice)
            }

            if let query = composer.paletteQuery {
                CommandPalette(directory: commands, query: query) { command in
                    // 只回填，不执行：带参数的命令要用户自己补完再按发送。
                    composer.pick(name: command.name)
                }
            }

            if !isComposing {
                ComposerStrip(
                    model: stripModel,
                    onTapModel: { activeSheet = .model },
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
        // 兜底规则：选中值 ?? 目录默认 ?? 未知。目录默认值只为「重拉期间不闪成未知」。
        // 等级名与模型名读同一个 `shown`：两处各取一份会出现「模型是 A、等级是 B 的」。
        let shown = sync.displayedModel ?? catalog.lastKnownDefault
        return ComposerStripModel.make(
            phase: sync.phase,
            carrier: store.meshPath,
            usage: sync.usage,
            modelName: shown.map { $0.model } ?? "未知",
            effortName: catalog.effortLabel(for: shown)
        )
    }

    /// 本会话还挂着的卡。表按会话分组，这里只取这一栏 —— 别的会话的那几条不进这一屏。
    private var pendingApprovals: [ApprovalTable.Entry] {
        approvals.pending(in: session.id)
    }

    /// 待批卡：只露第一张，其余折成一行计数。
    ///
    /// 审批是串行的 —— 批完一张才该看下一张。同时露两张不提供额外判断信息，只会把输入框
    /// 再往上推 132pt，而那正是「挤」的主因。卡本身仍在输入框上方：它必须一眼看见。
    @ViewBuilder
    private var approvalSection: some View {
        if let first = pendingApprovals.first {
            ApprovalCard(approval: first, state: approvals.state(for: first.eventId)) { allow in
                Task { await approvals.answer(first, allow: allow) }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            if pendingApprovals.count > 1 {
                Button {
                    activeSheet = .approvals
                } label: {
                    Text("还有 \(pendingApprovals.count - 1) 个待批准")
                        .font(.footnote)
                }
                .padding(.bottom, 6)
            }
        }

        if let notice = approvals.notice(for: session.id) {
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
            TextField("发一条指令给 DSH…", text: $composer.text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .focused($isComposing)
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(!composer.canSubmit)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// 命令面板此刻开着没有 —— 只用来取「刚打开」那个边沿，好触发一次重拉。
    ///
    /// 读的是**归一化之后**的草稿，与 `send` 的分流同一份输入：各读一份原始草稿时，
    /// `" /permission"`（前导空格）会让这里判「不在敲命令」（不弹、不重拉）而发送判「是命令」。
    private var isCommandPaletteOpen: Bool {
        composer.paletteQuery != nil
    }

    /// 发送：一行字走哪条路，判定在 `SlashTrigger.dispatch` —— 视图只照它的结论办事。
    ///
    /// **草稿在「已受理」之后才清**：命令名字打错（`unknown-command`）是唯一用户能自己改好的
    /// 失败，那条路上把输入框清掉等于让人重打整行。
    ///
    /// **代价**：以 `/` 开头的普通消息发不出去（会被当命令）。与 Web UI 同 —— 它把整个
    /// 斜杠前缀交给了命令系统。
    private func send() {
        // 发送即收键盘：功能条跟着回来，用户能看到它接下来的连接态与占用。
        // 草稿由 `composer` 按「是否受理」决定留不留 —— 失败了那行字还在，改个字就能重按。
        isComposing = false
        Task { await composer.submit(sync.deliver) }
    }

    // MARK: - 详情面

    private var networkSheet: some View {
        NetworkSheet(phase: sync.phase,
                     carrier: store.meshPath,
                     lastFrameAt: sync.lastFrameAt,
                     nodeState: store.nodeState,
                     configDamaged: store.storedConfigDamaged,
                     onRetry: { sync.retry() },
                     onOpenMesh: { activeSheet = .mesh })
    }

    /// 折叠起来的那些卡。**不含**上方已经露出的第一张 —— 文案说「还有 N 个」，列出来的就该是 N 个。
    private var allApprovalsSheet: some View {
        let rest = Array(pendingApprovals.dropFirst())
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
                                             state: approvals.state(for: approval.eventId)) { allow in
                                    Task { await approvals.answer(approval, allow: allow) }
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

    /// 本屏五个展开面。合成一个 `.sheet(item:)` 的 id。
    private enum DetailSheet: String, Identifiable {
        case network
        case usage
        case approvals
        case mesh
        case model

        var id: String { rawValue }
    }

    /// 底部滚动锚点的 id。
    private static let bottomAnchor = "session-detail-bottom"

    /// 距顶多近就自动往回翻。取约四分之一屏 —— 太灵敏会在惯性里连着触发好几次。
    private static let topTriggerDistance: CGFloat = 240

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

import SwiftUI

/// 单个会话的消息视图 —— 这一屏的**渲染段**。依赖全在容器里，零服务。
/// 容器由 `SessionDetailAssembler` 造并接线；首帧为 nil 那种形态由装配段吸收。
struct SessionDetailView: View {
    let detail: SessionDetailState

    /// 是否已经做过「首次定位到最新」。之后的内容变化（往回翻的前插）不再抢视口。
    @State private var didInitialScroll = false
    /// 是否贴着底部。流式文本每帧都在长高，只有它为真时才跟着往下走；
    /// 用户一旦上滑离开底沿就置 false，否则会把正在读历史的人拽回去。
    @State private var isFollowingBottom = true
    /// 这一拍是不是用户的手在带着列表走。只有它和「离开底部」同时成立，才算「用户想读历史」。
    @State private var isUserDrivingScroll = false
    /// 本屏四个展开面。共用一个 `.sheet(item:)` 的理由见 `body` 里那段注释。
    @State private var activeSheet: DetailSheet?
    /// 等着确认的那一档。危险档位（完全权限 / 自动审查）先落在这里，确认后才发请求。
    @State private var confirming: PermissionState.Choice?
    /// 输入框有没有焦点：打字时功能条收起，把高度让给内容与键盘。
    @FocusState private var isComposing: Bool

    var body: some View {
        Group {
            if detail.isTranscriptEmpty {
                // 内容没到时不挂 List：空列表先出现再插几十行，会让「刷新出来、
                // 再滚下去」变成看得见的位移。
                // 这段还要自己撑满：`safeAreaInset` 的底栏贴在视图下边界，
                // ProgressView 只有一行高，底栏会浮到屏幕中间。
                ProgressView("正在同步…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }
        }
        // 每次开始敲命令时重拉一次；挂在面板上会让每敲一个字都拉一遍。
        .onChange(of: isCommandPaletteOpen) { _, open in
            guard open else { return }
            Task { await detail.commands.reload() }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBars
        }
        .navigationTitle(detail.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        // 四个面共用一个 `.sheet(item:)`：两个独立 sheet 在同一事务里「关一个开一个」时，
        // 第二个经常不 present。
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .network:
                networkSheet
            case .usage:
                UsageSheet(usage: detail.sync.usage)
            case .approvals:
                allApprovalsSheet
            case .model:
                ModelSheetView(
                    catalog: detail.catalog,
                    selected: detail.sync.displayedModel,
                    onSelect: { selection in Task { await detail.sync.selectModel(selection) } },
                    onClose: { activeSheet = nil }
                )
            }
        }
        // 危险档位的确认。文案来自 `Display/PermissionText.swift`，缺文案的档位不该走到这里
        // （`pick` 只在 `needsConfirmation` 时置位，而那个集合里的每一档都有文案）。
        .alert(confirming?.confirmation?.title ?? "", isPresented: isConfirming, presenting: confirming) { choice in
            Button(choice.confirmation?.confirm ?? "") {
                Task { await detail.permission.choose(choice.value) }
            }
            Button(PermissionState.Choice.cancel, role: .cancel) { confirming = nil }
        } message: { choice in
            Text(choice.confirmation?.message ?? "")
        }
    }

    /// 确认框开着没有 —— `confirming` 是唯一出处，关掉它即关闭。
    private var isConfirming: Binding<Bool> {
        Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        )
    }

    /// 有内容之后才挂的那一屏 —— 创建时机就是「一进去停在最底部」的判据。
    private var transcript: some View {
        ScrollViewReader { proxy in
            List {
                // 翻页是自动的，这里只画「正在拉」的占位。给三行骨架而不是转圈：
                // 一片空白加个小转圈会让人以为到头了。
                if detail.sync.hasOlder && detail.sync.isPagingOlder {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(uiColor: .secondarySystemBackground))
                            .frame(height: 44)
                            .padding(.vertical, 2)
                            .listRowSeparator(.hidden)
                    }
                }

                if detail.sync.nodes.isEmpty {
                    Text("这个会话里没有可显示的内容。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(detail.sync.nodes) { node in
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

                // 流式输出不在镜像里 —— 未定稿内容没有 seq，不属于「已读到的位置」。
                // 源文变化时 `MarkdownText` 只重解析尾部。
                if !detail.sync.transientText.isEmpty {
                    Text("DSH 正在输入…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    MarkdownText(source: detail.sync.transientText, caching: false)
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
                    Text("共 \(detail.sync.eventCount) 条事件，其中 \(detail.sync.messageCount) 条消息 · \(detail.sync.status.line)")
                }

                // 滚动锚点**必须在 footer 之后**：摆在 footer
                // 之前时那条说明会被挤出可视区，看起来像没滚到底。
                Color.clear
                    .frame(height: 1)
                    .listRowSeparator(.hidden)
                    .id(Self.bottomAnchor)
            }
            .listStyle(.plain)
            // 首次布局就锚在底部。列表是**有内容之后才创建**的，所以此刻它算「初始布局」。
            .defaultScrollAnchor(.bottom)
            // 往回翻是往顶部插行，不走隐式动画：一次插几十行的布局动画很贵，
            // 用户也不需要看见内容长出来。
            .animation(nil, value: detail.sync.eventCount)
            // 滑到接近顶部就自动往回翻。只认进入边沿：前插后内容变高、离顶更远，条件自然复位。
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top <= Self.topTriggerDistance
            } action: { wasNear, isNear in
                guard isNear, !wasNear, detail.sync.hasOlder, !detail.sync.isPagingOlder else { return }
                Task { await detail.sync.loadOlder() }
            }
            // 跟随底部之一：谁在带着列表走。程序性滚动（我们自己的 scrollTo）不算。
            .onScrollPhaseChange { _, phase in
                isUserDrivingScroll = phase != .idle
            }
            // 跟随底部之二：位置判定。
            // 只做两件事 —— 回到 底部就恢复跟随；离开 底部且**确是用户在拖**才不再跟随。
            // 程序性变化（文本长高、键盘升降、换基线）不算「用户想读历史」：否则一次大跳就会
            // 把跟随关掉，之后再也不会自己接上。
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // 用「离底距离」而不是「可见矩形下沿」—— 键盘弹出时容器变矮、底 inset 同步变大，
                // 两者在下面这个式子里互相抵消，才不会误判成「已经上滑」。
                let maxOffset = geometry.contentSize.height
                    + geometry.contentInsets.bottom
                    - geometry.containerSize.height
                return geometry.contentOffset.y >= maxOffset - Self.bottomFollowThreshold
            } action: { _, atBottom in
                if atBottom {
                    isFollowingBottom = true
                } else if isUserDrivingScroll {
                    isFollowingBottom = false
                }
            }
            // 跟随底部之三：内容变高时跟上。
            // 挂在 `contentSize` 上而不是 `onChange(of: transientText)`：文本刚变的那一刻新行还没
            // 布局，`scrollTo` 会落到**旧的**底部 —— 一帧差一行，越跟越丢。
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                // 只认「变高」：变矮（清场、换基线）不追；也避免滚动本身把这条再次触发。
                guard isFollowingBottom, new > old else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onAppear {
                // 与上面同一个目标：列表最末尾那行锚点。**无动画** —— 生效时等于原地不动，
                // 不生效时也只是瞬移，而不是用户能看见的「滚下去」。
                guard !didInitialScroll else { return }
                didInitialScroll = true
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            // 不用 `.refreshable`：它的语义是「拉最新」却只能挂在顶部，而顶部该做的是往回翻。
            // 打字时滚动列表即收键盘 —— 与配对屏同口径；这是功能条回来的手势。
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: - 底栏

    /// 底栏分五段：审批卡 → 告知 → 命令候选 → 功能条 → 输入行。
    /// 命令候选贴近输入框：它是「当前这一行」的补充。
    private var bottomBars: some View {
        VStack(spacing: 0) {
            approvalSection

            if let notice = detail.sync.notice {
                noticeRow(notice)
            }

            // 切权限失败单独一行：那一格本身要保持原值（不乐观更新），失败只能在这里说。
            if let failure = detail.permission.failureLine {
                permissionFailureRow(failure)
            }

            if let query = detail.composer.paletteQuery {
                CommandPalette(directory: detail.commands, query: query) { command in
                    // 只回填，不执行：带参数的命令要用户自己补完再按发送。
                    detail.composer.pick(name: command.name)
                }
            }

            if !isComposing {
                ComposerStrip(
                    model: detail.stripModel(),
                    permissionChoices: detail.permission.choices,
                    onSelectPermission: pick,
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

    /// 待批卡：只露第一张，其余折成一行计数。
    /// 审批是串行的：同时露两张不提供额外信息，只会把输入框再往上推 132pt。
    @ViewBuilder
    private var approvalSection: some View {
        // 一次求值给这一节用 —— 它在 body 里被读三处（首张、计数、计数减一）。
        let pending = detail.pendingApprovals
        if let first = pending.first {
            ApprovalCard(approval: first, state: detail.approvals.state(for: first.eventId)) { allow in
                Task { await detail.approvals.answer(first, allow: allow) }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            if pending.count > 1 {
                Button {
                    activeSheet = .approvals
                } label: {
                    Text("还有 \(pending.count - 1) 个待批准")
                        .font(.footnote)
                }
                .padding(.bottom, 6)
            }
        }

        if let notice = detail.notice {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        }
    }

    /// 「内容没能接上 / 已清空重来」的告知，挂在**不随内容滚动**的底栏里。
    /// 同步状态行在 List 的 footer（跟着内容滚），用户往回翻时正好看不见，
    /// 而那正是最需要看见的时候。
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

    /// 切权限失败那一行。橙色、不带图标 —— 它不是「内容接不上」，是一次动作没成。
    private func permissionFailureRow(_ line: String) -> some View {
        Text(line)
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
    }

    // MARK: - 权限

    /// 点一档：危险档位先过一次确认，其余直接切。
    /// 「哪几档危险」是判定（`Choice.needsConfirmation`），视图不比对字符串。
    private func pick(_ choice: PermissionState.Choice) {
        if choice.needsConfirmation {
            confirming = choice
        } else {
            Task { await detail.permission.choose(choice.value) }
        }
    }

    /// 输入行：宽度全给输入框，发送键在最右。输入框不带边框 —— 它坐在玻璃上，再加描边就是两层皮。
    @ViewBuilder
    private var composerRow: some View {
        // 局部 `@Bindable`：`@State` 的 `$` 只到对象这一层，取属性绑定要再包一次。
        @Bindable var composer = detail.composer
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
            .disabled(!detail.composer.canSubmit)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// 命令面板此刻开着没有 —— 只用来取「刚打开」那个边沿。
    /// 读的是归一化之后的草稿，与发送分流同一份输入。
    private var isCommandPaletteOpen: Bool {
        detail.composer.paletteQuery != nil
    }

    /// 发送：走哪条路判定在 `SlashTrigger.dispatch`，视图只照它的结论办事。
    /// **草稿在「已受理」之后才清**：命令名打错是用户能自己改好的失败，清掉等于让人重打整行。
    /// 代价：以 `/` 开头的普通消息发不出去（与 Web UI 同）。
    private func send() {
        // 发送即收键盘：功能条跟着回来，用户能看到它接下来的连接态与占用。
        // 草稿由 `composer` 按「是否受理」决定留不留 —— 失败了那行字还在，改个字就能重按。
        isComposing = false
        Task { await detail.composer.submit(detail.sync.deliver) }
    }

    // MARK: - 详情面

    private var networkSheet: some View {
        NetworkSheet(phase: detail.sync.phase,
                     carrier: detail.meshPath,
                     lastFrameAt: detail.sync.lastFrameAt,
                     nodeState: detail.nodeState,
                     configDamaged: detail.configDamaged,
                     onRetry: { detail.sync.retry() })
    }

    /// 折叠起来的那些卡。**不含**上方已经露出的第一张 —— 文案说「还有 N 个」，列出来的就该
    /// 是 N 个。
    private var allApprovalsSheet: some View {
        let rest = Array(detail.pendingApprovals.dropFirst())
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
                                             state: detail.approvals.state(for: approval.eventId)) { allow in
                                    Task { await detail.approvals.answer(approval, allow: allow) }
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
    /// 组网设置不在其中：详情只展示组网事实，配置入口在设置页（未就绪时整屏就是配置页）。
    private enum DetailSheet: String, Identifiable {
        case network
        case usage
        case approvals
        case model

        var id: String { rawValue }
    }

    /// 底部滚动锚点的 id。
    private static let bottomAnchor = "session-detail-bottom"

    /// 距顶多近就自动往回翻。取约四分之一屏 —— 太灵敏会在惯性里连着触发好几次。
    private static let topTriggerDistance: CGFloat = 240

    /// 距底多近仍算「贴着底部」。留一点余量：手指精度与行高误差不该让跟随状态抖成 false。
    private static let bottomFollowThreshold: CGFloat = 60

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

/// 底栏材质：iOS 26 起用玻璃，以下退回 `.bar`。
/// 抽成 modifier：availability 分支夹在 body 里会让人以为两态布局不同，其实只是材质。
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

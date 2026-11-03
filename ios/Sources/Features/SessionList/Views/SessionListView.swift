import SwiftUI

/// 会话列表 —— **全应用的首屏**。取数与「显示哪些」在 `SessionListState`；本文件只画，
/// 加四个触发点（进屏首载、下拉、回前台、组网就绪）—— 那是平台事件与用户手势。
/// **它永远是根**：前置条件不满足时不换屏，只在顶部给一条提示。
struct SessionListView: View {
    let list: SessionListState
    /// `phase` 驱动「就绪即首载」，`meshPath` 给底部那条状态带。
    let store: MeshStore

    /// 回前台立即刷新：App 生命周期与列表域的连接点。
    @Environment(\.scenePhase) private var scenePhase

    /// 输入面板开着吗。**这是视图的本地值**：它只管「这一层皮在不在」，
    /// 名字合法与否归 `WorkspaceName`，判定（发不发请求）与创建结果归状态层。
    @State private var isNaming = false
    /// 面板里那个输入框的内容。输入的**持有者**是视图，规则不在这里。
    @State private var draftName = ""
    /// 正等着确认删除的那一组。`nil` 表示没有框开着 —— 它同时也是 `confirmationDialog`
    /// 的呈现条件，所以不另设一个布尔。
    @State private var pendingDeletion: PendingDeletion?

    var body: some View {
        pairedList
    }

    /// 打开「新建工作空间」的输入面板。
    ///
    /// 名字预填 `workspace-N`（**已注册**的那些里第一个空闲的）—— 用户多数时候只想赶紧建
    /// 一个，不该被要求从零想个名字。根下还没注册的目录看不见，那种情况交给服务端撞。
    private func startNamingWorkspace() {
        draftName = WorkspaceName.suggestion(among: list.workspaces.map(\.title))
        list.beginNamingWorkspace()
        isNaming = true
    }

    /// 提交名字。判定在状态层（不合法就不发请求），这里只发起 —— 视图不接结果。
    private func submitName() {
        Task { await list.submitWorkspaceName(draftName) }
    }

    private func closeNaming() {
        isNaming = false
        draftName = ""
    }

    /// 这一次提交已经有结论（建好了 / 已经有了）—— 收口按钮该说「完成」。
    ///
    /// 失败时仍是「创建」：那是重新试一次，不是收口。
    private var hasOutcome: Bool {
        switch list.workspaceCreation {
        case .some(.created), .some(.alreadyExists): return true
        default: return false
        }
    }

    /// 名字不能用的理由，说人话。
    private func text(of problem: WorkspaceName.Problem) -> String {
        switch problem {
        case .blank: return "名字不能是空的。"
        case .pathSeparator: return "名字里不能有斜杠。"
        case .dotEntry: return "「.」和「..」不能当名字。"
        }
    }

    /// 创建结果，说人话。
    private func text(of creation: WorkspaceCreation) -> String {
        switch creation {
        case .created: return "建好了。关掉这里就能在列表里看到它。"
        case .alreadyExists: return "这个工作空间已经有了，不用再建一次。"
        case .failed(let reason): return reason
        }
    }

    /// 「新建工作空间」的输入面板。
    ///
    /// 只输一个名字：目录落在哪由网关决定（固定的根，与 Web UI 首次使用的是同一个父目录），
    /// 所以这里**不出现任何目录浏览**。创建结果由状态层带回，面板只负责把它说人话。
    private var namingSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("工作空间名字", text: $draftName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if let problem = list.workspaceNameProblem {
                        Text(text(of: problem)).foregroundStyle(.red)
                    } else if let creation = list.workspaceCreation {
                        Text(text(of: creation))
                    } else {
                        Text("名字就是 Mac 上那个目录的名字，会建在「文稿/deepseek-harness」下面。")
                    }
                }
            }
            .navigationTitle("新建工作空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasOutcome ? "关闭" : "取消") { closeNaming() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if hasOutcome {
                        // 建好了就得有一个**语义正确**的收口动作。只留「取消」的话，
                        // 用户对着一次成功会被要求点一个写着「放弃」的按钮。
                        Button("完成") { closeNaming() }
                    } else {
                        Button("创建") { submitName() }
                            .disabled(list.isCreatingWorkspace)
                    }
                }
            }
        }
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

    /// 底部那条状态带。`nil` = 没什么要说，整条不出现（直连且没出错时的常态）。
    ///
    /// 判定在 `ConnectionStatusBarModel.make`：这里只把两个来源交进去 ——
    /// 路径来自组网，失败来自列表自己的上一次读取。
    private var statusBar: ConnectionStatusBarModel? {
        ConnectionStatusBarModel.make(carrier: store.meshPath, failure: list.failureText)
    }

    /// 确认框的标题：点的是哪一组就点它的名。
    private var deletionTitle: String {
        pendingDeletion.map { WorkspaceDeletionText.title(for: $0.title) } ?? ""
    }

    /// 确认框的呈现条件。用 `pendingDeletion` 反推而不是另设一个布尔：
    /// 两个状态描述同一件事，就一定会有一刻它们不一致。
    private var deletionIsPresented: Binding<Bool> {
        Binding(get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } })
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
                let expanded = list.isExpanded(group.id)
                // 组的标题是**卡片里的第一行**，不是 Section 的 header。
                //
                // 这个位置不是排版偏好：`Section` 的 header 渲染在卡片**之外**，而那些行
                // 一个都不画时（折叠，或一个空工作空间），整张卡片都不会出现 —— 只剩一行
                // 灰色小字悬在空白里，与它管辖的东西脱开。放进卡片里之后，「一组 = 一张卡」
                // 在最少的形态下也成立：折叠的组就是一张只有标题行的卡。
                Section {
                    GroupHeaderRow(title: title(of: group),
                                   count: group.sessions.count,
                                   isExpanded: expanded,
                                   isRunning: group.hasRunning,
                                   isUngrouped: group.isUngrouped,
                                   isBusy: list.isCreating || list.isDeletingWorkspace,
                                   onToggle: {
                                       withAnimation(.snappy) { list.toggleExpansion(group.id) }
                                   },
                                   onCreate: {
                                       Task { await list.createSession(in: group.id) }
                                   },
                                   onDelete: {
                                       pendingDeletion = PendingDeletion(
                                           id: group.id,
                                           title: title(of: group),
                                           sessionCount: group.sessions.count)
                                   })
                        .listRowInsets(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 8))

                    // 折叠只是不画：`list.sessions` 里那些行一个都没少，事件照常落进去。
                    // 展开时看到的是最新的一份，不需要再读一次列表。
                    if expanded {
                        ForEach(group.sessions) { session in
                            NavigationLink(value: Destination.session(sessionId: session.id,
                                                                      title: session.title)) {
                                SessionRow(session: session)
                            }
                        }
                    }
                }
            }
        }
        // 显式声明分组样式：一组一张卡这件事要靠它，而不是靠默认值 -- 默认值随平台
        // 与层级变化，而「组是卡片、组之间有空隙」是这一屏的结构，不是巧合。
        .listStyle(.insetGrouped)
        .navigationTitle("会话")
        .overlay {
            if list.isLoading && groups.isEmpty {
                ProgressView("正在读 Mac 上的会话…")
            } else if groups.isEmpty
                        && list.failureText == nil && list.blockedReason == nil {
                ContentUnavailableView {
                    Label("还没有工作空间", systemImage: "folder")
                } description: {
                    // 走到这里意味着连一个工作空间都没有 —— 会话只能活在某个工作空间里，
                    // 所以这里唯一的动作是建一个（不是「新建会话」）。
                    Text("在手机上建一个：给它起个名字，剩下的交给 Mac。")
                } actions: {
                    Button("新建工作空间") { startNamingWorkspace() }
                        .disabled(list.isCreatingWorkspace)
                }
            }
        }
        .sheet(isPresented: $isNaming) { namingSheet }
        .confirmationDialog(deletionTitle,
                            isPresented: deletionIsPresented,
                            titleVisibility: .visible,
                            presenting: pendingDeletion) { target in
            // 破坏性动作在前，取消在后 —— 系统会给 destructive 那一项红色。
            Button("删除", role: .destructive) {
                let workspaceId = target.id
                pendingDeletion = nil
                Task { await list.deleteWorkspace(workspaceId) }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { target in
            // 这三件事必须说：用户看到「删除」两个字，默认理解是「项目没了」。
            Text(WorkspaceDeletionText.message(sessionCount: target.sessionCount))
        }
        .refreshable { await list.reload() }
        // 状态带贴在底边而不是进 List 的页脚：页脚跟着内容滚，用户往回翻时正好看不见，
        // 而「现在断没断」恰恰是那时候最需要知道的。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let statusBar {
                ConnectionStatusBar(model: statusBar) {
                    Task { await list.reload() }
                }
            }
        }
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
            ToolbarItem(placement: .topBarTrailing) {
                // 顶层唯一的「新建」：造一个工作空间。会话由各组的标题行按钮建 ——
                // 两步各自只做一件事，谁失败都看得出是哪一步。
                Button {
                    startNamingWorkspace()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .disabled(list.isCreatingWorkspace)
                .accessibilityLabel("新建工作空间")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 设置是唯一常驻入口：组网与身份两条都在里面。**它永远在** ——
                // 前置条件不满足时，用户要修的东西就在那里。
                NavigationLink(value: Destination.settings) {
                    Image(systemName: "gearshape")
                }
            }
        }
    }
}

/// 正等着确认删除的那一组。
///
/// 会话数在按下删除菜单那一刻就定下来了：确认框里那句「里面的 N 个会话会移到未分组」
/// 说的是**用户看到的那个数**，而在框开着的时候列表可能已经变了 —— 显示一个在他点开框之后
/// 才变过的数只会让他怀疑自己看错了。
private struct PendingDeletion {
    let id: String
    let title: String
    let sessionCount: Int
}

/// 一组的标题行，**住在组那张卡里**：左侧整块是折叠开关，右侧那两个动作只在展开时出现。
///
/// 它与组内会话同属一张卡，所以它读起来是这个块的标题栏，而不是悬在块外面的一行说明。
/// 折叠时这张卡就只剩它自己 —— 那是「一个收起来的分组」该有的样子。
///
/// 折叠开关做成一个 `Button` 包住「箭头 + 标题 + 计数」，而不是给整行挂 `onTapGesture`：
/// 后者会与右侧的「+」抢手势，而误触的代价是「想建会话，结果把组收起来了」。
private struct GroupHeaderRow: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    /// 组里有会话在跑。折叠之后这是唯一的痕迹 —— 否则「有东西在动」与「静止」长得一样。
    let isRunning: Bool
    /// 这一组背后没有工作空间（「未分组」）—— 既没有地方落新会话，也没有东西可删。
    ///
    /// 它仍然用与真工作空间**同样的**标题样式：那三个动作的缺席已经足以说明它不是工作空间，
    /// 而把标题调小调浅会让它比组内的会话行还轻（它是容器，会话是内容）。
    let isUngrouped: Bool
    let isBusy: Bool
    let onToggle: () -> Void
    let onCreate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())

                    if isRunning {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)，\(count) 个会话，\(isExpanded ? "已展开" : "已折叠")")

            Spacer(minLength: 8)

            if isExpanded && !isUngrouped {
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .accessibilityLabel("在「\(title)」里新建会话")

                // 删除收在菜单里：它是破坏性的，多一层「点进去才看得到」是好事；
                // 而组标题不是行，滑动删除在它上面做不干净。
                Menu {
                    Button("删除工作空间", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.medium))
                        .frame(width: 30, height: 22)
                }
                .disabled(isBusy)
                .accessibilityLabel("「\(title)」的更多操作")
            }
        }
    }
}

/// 列表里的一行会话：一行主文本 + 右侧时间。
///
/// 时间是「你上次发言」而不是「它上次动过」（协议 v2 起如此）。那三个字从视觉上去掉了 ——
/// 每行都写一遍是纯噪声 —— 但留在 `accessibilityLabel` 里：对扫视的人多余，对读屏的人是信息。
private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 8) {
            // 进行中用一个圆点，不用文字标签：标签会与长标题抢宽度，也会多出一个色块。
            if session.running {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }

            Text(session.title ?? "（无标题）")
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(relativeTime(session.updatedAt))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenText)
    }

    private var spokenText: String {
        let title = session.title ?? "无标题会话"
        let when = "最后发言于\(relativeTime(session.updatedAt))"
        return session.running ? "\(title)，进行中，\(when)" : "\(title)，\(when)"
    }
}

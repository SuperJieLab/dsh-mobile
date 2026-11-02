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

    /// 输入面板开着吗。**这是视图的本地值**：它只管「这一层皮在不在」，
    /// 名字合法与否归 `WorkspaceName`，判定（发不发请求）与创建结果归状态层。
    @State private var isNaming = false
    /// 面板里那个输入框的内容。输入的**持有者**是视图，规则不在这里。
    @State private var draftName = ""

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
                    HStack {
                        Text(title(of: group))
                        Spacer()
                        // 未分组的组没有工作空间可落，所以不给入口 —— 「不指定工作空间」
                        // 那条路在手机端已经关掉了。
                        if !group.isUngrouped {
                            Button {
                                Task { await list.createSession(in: group.id) }
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .disabled(list.isCreating)
                            .accessibilityLabel("在「\(title(of: group))」里新建会话")
                        }
                    }
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

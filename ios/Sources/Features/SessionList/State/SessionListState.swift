/**
 * 会话列表的状态：取一次，把结果落成三种面 —— 有内容 / 前置不满足 / 真失败。
 *
 * 只回答「取回来是什么」，**不回答「什么时候取」**：触发点归视图。唯一的例外是事件流的代次
 * （那是「恢复」这个事实本身）。失败不清空已有列表；前置不满足是 `blocked` 而非 `failed`。
 */
import Foundation

/// 列表从那条流上要的两件事：一条增量、一次报到。
///
/// **收窄成协议而不是吃具体类**：`SessionListState` 不该认识「流怎么开、帧怎么判」。
/// 收窄之后它的测试可以把这两个口替掉 —— 拆流之前那一层的注释写着「具体类替不进去，
/// 所以只能靠数注册次数」，那条限制随着拆流一起消失了。
@MainActor
protocol SessionListEventSink {
    @discardableResult
    func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void
    @discardableResult
    func onReady(_ handler: @escaping () -> Void) -> () -> Void
}

@MainActor
@Observable
final class SessionListState {

    /// `blocked` 与 `failed` 的分界不在严重程度，在**谁的问题**：前者是这台机器还差一步
    /// 配置（用户去设置里做），后者是这次请求坏了。两者的文案都是服务端原文。
    enum Outcome: Equatable {
        case ready
        case blocked(String)
        case failed(String)
    }

    private(set) var sessions: [SessionSummary] = []
    /// 组清单，顺序即显示顺序。**来自组流**（`workspace/follow`），不跟列表应答走 ——
    /// 一条应答里同时给行与组，就会出现「行是新的、组是旧的」这种半新半旧的组合。
    private(set) var workspaces: [WorkspaceView] = []
    /// 归属表：会话 id → 工作空间 id。组清单一变就重算（`SessionOwners`），不另存第二份。
    private(set) var owners: [String: String] = [:]
    /// 控制流推来的标题：会话 id → 标题。**只放推来的那些** —— 行自带的标题仍在行上，
    /// 合成规则在 `SessionRows.make`（一处）。
    private(set) var titles: [String: String] = [:]

    /// 渲染用的行：三源合成（行 + 标题；归属由分组那一步用 `owners`）。
    ///
    /// 现算而不是存一份：存一份就多了「标题变了要重算、行变了要重算」两个触发点，
    /// 漏一个的症状是某一行停在旧标题上。两个入参都在本对象里，现算没有额外代价。
    var rows: [SessionRow] { SessionRows.make(sessions, titles: titles) }
    private(set) var isLoading = false
    /// 正在让宿主建一个空会话。视图用它禁用入口 —— 连发两次只会让两个动作抢同一行状态。
    private(set) var isCreating = false
    /// 正在让宿主造一个工作空间。
    private(set) var isCreatingWorkspace = false
    /// 正在让宿主删掉一个工作空间。
    private(set) var isDeletingWorkspace = false
    /// 上一次创建工作空间的结果；`nil` 表示这次还没发起过。视图据它给提示 ——
    /// 结果留在这里而不是交回调用方，视图才不必接 `await` 的返回值。
    private(set) var workspaceCreation: WorkspaceCreation?
    /// 上一次提交被名字规则拒掉的理由。**判断在这里，不在视图**：视图里那句
    /// `if problem != nil { return }` 删掉不会有任何判据变红，而它守的正是 spec 的
    /// 「非法名字一个请求都不发」。
    private(set) var workspaceNameProblem: WorkspaceName.Problem?
    /// 哪些组被点开了。默认全折（`GroupExpansion` 的初值是空集合）。
    private(set) var expansion: GroupExpansion
    private(set) var outcome: Outcome = .ready

    /// 取一次列表。收成闭包是为了让「在途期间发生了什么」可被断言 ——
    /// 走真网络时，「两次请求并发」与「一次请求很慢」在测试里长得一样。
    private let fetch: () async throws -> [SessionSummary]
    /// 让宿主建一个空会话、交回 id。与 `fetch` 一样注入：新建的失败面要能被断言，
    /// 而走真网络时「宿主拒绝」与「网络断了」在测试里长得一样。
    ///
    /// 参数是落在哪个工作空间；`nil` 表示不指定（宿主用它自己的当前目录）。
    private let create: (String?) async throws -> String
    /// 让宿主造一个工作空间。同样注入，理由同上。
    private let createWorkspaceAction: (String) async throws -> WorkspaceCreated
    /// 让宿主删掉一个工作空间。注入的理由同 `create` —— 「宿主拒绝」与「网络断了」在
    /// 测试里长得一样，而这一条要断言的是「拒绝时列表没动」。
    private let deleteWorkspaceAction: (String) async throws -> Void
    /// 建好之后去哪 —— 由装配段给（它握着导航栈）。**不叫 `navigate`**：这一层不认识
    /// `Destination` 那张路由表，它只知道「拿这个 id 去看那一条会话」。
    private let open: (String) -> Void
    /// 把展开状态落盘。注入的理由与 `fetch` 相同：测试要能断言「真的写了」，而真写
    /// `UserDefaults` 时「写了」与「没写」在测试里长得一样。
    private let persistExpansion: (GroupExpansion) -> Void
    /// 在途的那一次。单飞的落点，也是这批账的归属。
    private var inflight: Task<[SessionSummary], Error>?
    /// 这一次在途期间到达的变更，按到达顺序。进 `reload` 时必然为空 —— `apply` 只在
    /// `inflight != nil` 时入账，而它只在 `reload` 体内非 nil。
    private var buffered: [SessionListChange] = []
    /// 是否已经听过事件流（`attach` 幂等）。
    private var attached = false
    /// 组流的当前来源。`attach(workspaces:)` 之后才非 nil。
    private var workspaceSource: (any WorkspaceListSource)?
    /// 是否已经听过组流（`attach(workspaces:)` 幂等）。
    private var workspacesAttached = false
    /// 是否已经听过控制流的标题投影（`attach(titles:)` 幂等）。
    private var titlesAttached = false
    init(fetch: @escaping () async throws -> [SessionSummary],
         create: @escaping (String?) async throws -> String,
         createWorkspace: @escaping (String) async throws -> WorkspaceCreated,
         deleteWorkspace: @escaping (String) async throws -> Void,
         open: @escaping (String) -> Void,
         expansion: GroupExpansion,
         persistExpansion: @escaping (GroupExpansion) -> Void) {
        self.fetch = fetch
        self.create = create
        self.createWorkspaceAction = createWorkspace
        self.deleteWorkspaceAction = deleteWorkspace
        self.open = open
        self.expansion = expansion
        self.persistExpansion = persistExpansion
    }

    convenience init(client: RpcClient, open: @escaping (String) -> Void) {
        self.init(fetch: { try await fetchSessions(client) },
                  create: { try await createBlankSession(client, in: $0) },
                  createWorkspace: { try await makeWorkspace(client, name: $0) },
                  deleteWorkspace: { try await removeWorkspace(client, workspaceId: $0) },
                  open: open,
                  expansion: .load(),
                  persistExpansion: { $0.save() })
    }

    /// 失败面的读法，不是第二份状态。
    var failureText: String? {
        if case .failed(let text) = outcome { return text }
        return nil
    }

    /// 前置那一面的读法；视图据此决定画中性提示还是红条。
    var blockedReason: String? {
        if case .blocked(let text) = outcome { return text }
        return nil
    }


    /// 听那条流。这条流不重放，所以「两次报到之间的事件」可能已经丢了 —— 报到是它在
    /// 客户端唯一可观察的形式，也是重读列表的唯一时机。幂等：视图重复出现时不该注册第二个听众。
    func attach(stream: any SessionListEventSink) {
        guard !attached else { return }
        attached = true
        // 两件都接：逐条的增量（改一行），与每一次报到（重拉基线）。少接一条的症状是
        // 「列表不自己动」或「断线之后再也不对齐」—— 都不编译失败。
        // 增量的解释在这里：挖 `change`、解形状、认不出丢弃。
        stream.onEmit { [weak self] event, args in
            guard let change = SessionListEvents.changeOf(event: event, args: args) else {
                Log.warn(Log.Module.session, "dropped a session event this build does not know",
                         ["event": String(describing: event)])
                return
            }
            self?.apply(change)
        }
        stream.onReady { [weak self] in
            // 报到与「动作成功后刷新」是同一关：撞在途时只等那一次，会把在途发出时刻的
            // 快照当成最新，而这条流不补发，下一次报到不知要等多久。
            Task { await self?.reloadAfterAction() }
        }
    }

    /// 听组流。与 `attach(stream:)` 同一条纪律：幂等（视图重跑 `.task` 是常态）。
    ///
    /// 先取一次当前清单再订阅 —— 组流可能早于这一屏建好（它是 App 级的），那一次
    /// `baseline` 已经到过；只订阅不取，列表会一直停在「未分组」直到下一次组变化。
    func attach(workspaces source: any WorkspaceListSource) {
        guard !workspacesAttached else { return }
        workspacesAttached = true
        workspaceSource = source
        absorbWorkspaces()
        source.onWorkspacesChanged { [weak self] in
            self?.absorbWorkspaces()
        }
    }

    /// 听控制流。**只取 `title` 这一格**：同一条投影里还有用量、权限那些，各有各的消费者。
    ///
    /// 基线到达时也会走这里（`updateListeners` 对基线与增量一视同仁），所以冷启动后
    /// 列表的标题会被一次性补齐，不需要另开一条读。
    func attach(titles stream: ControlStream) {
        guard !titlesAttached else { return }
        titlesAttached = true
        stream.updateListeners.add { [weak self] sessionId, values, _ in
            // 非字符串（含 `null`）不覆盖：那是「投影这一格读不出」，不是「标题被清空」。
            guard let title = values["title"]?.string else { return }
            self?.titles[sessionId] = title
        }
    }

    /// 组清单换了：重算归属表，别的一个字不动。
    ///
    /// **不重拉列表**：组与行是两份事实，组变了不代表行变了。把它接成「组一变就重读」
    /// 就是判据 5 要排除的那条 —— 组流断了，列表也跟着不动。
    private func absorbWorkspaces() {
        guard let source = workspaceSource else { return }
        workspaces = source.workspaces
        owners = SessionOwners.of(source.workspaces)
    }

    /// 一条列表增量。立即生效；在途时同时记进这一批账，等落地后重放到响应上。
    ///
    /// **可见性两条路都要筛**：事件推来的行若不过 `SessionVisibility`，`blank`（在 Mac 上
    /// 刚点新建、还没说话）与 `subagent` 会当场出现，下拉之后又消失。
    func apply(_ change: SessionListChange) {
        sessions = visible(SessionListMerger.apply(change, to: sessions))
        if inflight != nil { buffered.append(change) }
    }

    private func visible(_ rows: [SessionSummary]) -> [SessionSummary] {
        rows.filter(SessionVisibility.isVisible)
    }

    /// 服务端给出事实（`blank` / `origin`），**显示哪些**由 `SessionVisibility` 答。
    ///
    /// @returns 这一次**真的发出去了**吗。撞在途时只等它收尾、不重发，返回 `false` ——
    ///   调用方拿它决定要不要再试一轮（见 `reloadAfterAction`）。
    @discardableResult
    func reload() async -> Bool {

        if let running = inflight {
            _ = try? await running.value
            return false
        }
        let task = Task { try await fetch() }
        inflight = task
        isLoading = true
        defer {
            inflight = nil
            buffered = []
            isLoading = false
        }
        do {
            let rows = try await task.value
            // 先摆响应的顺序，再把这批账依次重放 —— 反过来会让事件带来的位置被响应冲掉。
            var merged = visible(rows)
            for change in buffered { merged = SessionListMerger.apply(change, to: merged) }
            // 重放会把事件推来的行加回去，所以落地之后再筛一次 —— 只筛一次的话，在途
            // 期间到达的 blank / subagent 会从这里漏进列表。
            sessions = visible(merged)
            outcome = .ready
        } catch {
            // 列表保留（事件带来的变化已经生效），只换失败面。
            //
            // 分类只看错误的类型，**不去推算「现在缺什么」**：`FailureText` 已经把两种前置
            // 说成了两句不同的话（组网未就绪 / 还没有配对），端上再猜一遍就会有两个说法。
            //
            // 留痕与失败面各管一件事：界面上的红条讲「现在怎样」，日志讲「哪一次为什么没成」——
            // 用户报「列表不动」时，只有日志能回答是没发出去、还是发了但失败了。
            Log.warn(Log.Module.session, "session list fetch failed",
                     ["reason": error.localizedDescription])
            record(failure: error)
        }
        return true
    }
}

extension SessionListState {

    /// 在某个工作空间里建一个空会话；建成就把它交给 `open`（装配段据此推进一屏），
    /// 失败落失败面。
    ///
    /// **不碰列表**：新建出来的一定是 `blank`，而 `blank` 不进列表（`SessionVisibility`）——
    /// 读一次只会白读。它要等第一条消息之后才出现，这是上游对 `blank` 的定义，不是缺陷。
    /// 宿主对同目录的空会话有复用规则，所以连点也不会堆出多个（那条不由本方法承诺）。
    ///
    /// @param workspaceId - 落在哪个工作空间；`nil` 表示交给宿主的当前目录。
    func createSession(in workspaceId: String?) async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let sessionId = try await create(workspaceId)
            open(sessionId)
        } catch {
            record(failure: error)
        }
    }

    /// 提交一个名字：**规则先判**，不合法就停在这里，一个请求也不发。
    ///
    /// 这一步住在状态层而不是视图里：它是「发不发请求」的判定，删掉它不会有任何判据变红
    /// —— 而 `WorkspaceNameTests` 只证明规则算得对，证明不了它被用上。
    ///
    /// @param raw - 用户输入的原样。规则与 trim 各做一次，都在 `WorkspaceName` 里。
    func submitWorkspaceName(_ raw: String) async {
        if let problem = WorkspaceName.problem(with: raw) {
            workspaceNameProblem = problem
            return
        }
        workspaceNameProblem = nil
        await createWorkspace(name: raw)
    }

    /// 造一个工作空间。成功（新建或本已存在）都重拉一次列表。
    ///
    /// **重拉的理由不是「组变了」**：组清单来自组流，`reload()` 一个字都不碰它。重拉是因为
    /// 宿主把会话挂进新组之后，`items[].sessionIds` 会变 —— 而那一份是组流推的，所以严格
    /// 说这一次重拉只为「行的 `updatedAt`/`blank` 可能刚被宿主动过」。留着它是因为代价是
    /// 一次读、而漏掉的代价是一行停在旧状态上；但它不承担「让新组出现」这件事。
    ///
    /// **不做本地插入**：组清单来自组流，宿主建好之后会推一条 `upsert`。本地先插一份
    /// 就多了一个「这一次的组」的临时真相，而它与流推来的那一份迟早不一致（标题、
    /// 顺序、甚至 id 都可能不同）。
    ///
    /// 结果落在 {@link workspaceCreation} 上而不是交回调用方 —— 视图只发起、不接结果
    /// （与新建会话同一条纪律）。失败也**只落这里**，不落列表顶部：动作是在输入面板里
    /// 发起的，用户的眼睛在那儿；两处显示同一句话，两处迟早不一致。
    ///
    /// @param name - 用户输入的原样；这里 trim 一次，不判合法性（`WorkspaceName` 的家）。
    func createWorkspace(name: String) async {
        guard !isCreatingWorkspace else { return }
        isCreatingWorkspace = true
        defer { isCreatingWorkspace = false }
        do {
            let made = try await createWorkspaceAction(WorkspaceName.trimmed(name))
            workspaceCreation = made.created ? .created : .alreadyExists
            await reloadAfterAction()
        } catch {
            workspaceCreation = .failed(error.localizedDescription)
        }
    }

    /// 让宿主解除一个工作空间的注册。
    ///
    /// 成功后重拉一次列表。
    ///
    /// **「那个组消失」由组流负责**（宿主解除注册后推一条 `remove`），`reload()` 不碰组清单；
    /// 重拉只为「那些会话的归属与 `blank` 可能刚变了」。**不做本地先行删除** —— 乐观地去掉
    /// 再补回来，中间那一帧是「删了但没删掉」，而删除的频率低到不值得为它引入一个需要回滚的状态。
    ///
    /// 失败落 {@link outcome}（列表顶部那条红）而不是别处：这一次是从列表上的确认框发起的，
    /// 框一关就没有承载失败的地方了 —— 与建工作空间相反，那个的失败落在输入面板里。
    ///
    /// @param workspaceId - 要解除注册的工作空间。
    func deleteWorkspace(_ workspaceId: String) async {
        guard !isDeletingWorkspace else { return }
        isDeletingWorkspace = true
        defer { isDeletingWorkspace = false }
        do {
            try await deleteWorkspaceAction(workspaceId)
            await reloadAfterAction()
        } catch {
            record(failure: error)
        }
    }

    /// 动作成功之后取一次**新**的列表。
    ///
    /// 不能直接 `reload()`：它在有在途请求时只等不重发，而在途那次的结果早于刚发生的事 ——
    /// 等它就等于把旧快照当最新，界面说「成功了」而列表里还是旧的。
    ///
    /// 所以每轮都问一句「这一发真的发出去了吗」，没发出去就再让一轮步；上限三轮。
    /// 在途那次的 body 从拿到值之后到收尾之间没有 `await`，因此一轮让步通常就够 ——
    /// 上限只是防它永远不让位。
    ///
    /// 它服务三个场景：建工作空间、删工作空间、流的报到（重连或首次开流）。
    ///
    /// 第三个别名不像「动作」：报到不是用户做的事。但它对重读的要求完全相同 ——
    /// 「这一发真的发出去了吗」。
    private func reloadAfterAction() async {
        for _ in 0..<3 {
            if await reload() { return }
            await Task.yield()
        }
        // 三轮都没让位：这一次刷新放弃。它不是「什么都没发生」—— 在途那一次的结果早于
        // 刚发生的事，界面会停在旧快照上。这条日志是这句话唯一的可查痕迹。
        Log.warn(Log.Module.session, "list refresh skipped — a read stayed in flight for every attempt")
    }

    /// 打开输入面板时清掉上一次的结果与拒绝理由 —— 否则「已经有了」会一直挂在那儿。
    func beginNamingWorkspace() {
        workspaceCreation = nil
        workspaceNameProblem = nil
    }

    /// 展开 / 收起一个组。视图只负责发起，结果落在 {@link expansion} 上。
    ///
    /// **这是折叠状态唯一会被改变的地方**。没有「新建后自动展开」那条规则：折叠的组上
    /// 不提供「新建会话」，所以「在折叠的组里建了东西」这个状态不存在，App 也就不需要
    /// 去撤销用户做过的折叠。
    ///
    /// @param groupId - 组的工作空间 id；未分组的组是空串。
    func toggleExpansion(_ groupId: String) {
        expansion.toggle(groupId)
        writeExpansion()
    }

    func isExpanded(_ groupId: String) -> Bool {
        expansion.isExpanded(groupId)
    }

    /// 写盘。**写之前先与当前所有组求交**，把已经不存在的组的记录清掉 —— 不等下一次
    /// 拉取，也不在拉取里做（那会让一次读带上写副作用）。
    ///
    /// 「所有组」取 `SessionGrouping` 的结果而不是 `workspaces.map(\.id)`：未分组也是组，
    /// 它的 id（空串）必须参与，否则用户点开它之后一次写盘就把它清了。
    ///
    /// `workspaces` 为空时**不求交**：空清单既可能是「一个工作空间都没有」，也可能是
    /// 「这一发没取到组清单」，后一种情况下清记录就是错的。
    private func writeExpansion() {
        if !workspaces.isEmpty {
            let known = Set(SessionGrouping.groups(rows: rows,
                                                  workspaces: workspaces,
                                                  owners: owners).map(\.id))
            expansion.retain(among: known)
        }
        persistExpansion(expansion)
    }

    /// 一次失败该落哪一面。`blocked` 与 `failed` 的分界见 `Outcome` 的注释；
    /// 分类只看错误类型，**不去推算「现在缺什么」**（`FailureText` 已经说过那句话了）。
    private func record(failure error: any Error) {
        if let gatewayError = error as? RpcClientError, Self.isPrerequisite(gatewayError) {
            outcome = .blocked(error.localizedDescription)
        } else {
            outcome = .failed(error.localizedDescription)
        }
    }

    /// 这个错误是不是「还差一步配置」而不是「这次请求坏了」。
    ///
    /// 只有两个取值在此列：隧道产物还没有、没有可用身份。其余（传输失败、状态码、协议
    /// 拒绝）都是这一次请求的事 —— 把它们说成配置问题，用户会去改一件没坏的东西。
    static func isPrerequisite(_ error: RpcClientError) -> Bool {
        switch error {
        case .notActivated, .unauthenticated: return true
        default: return false
        }
    }
}

/// 拉会话列表。服务端已按 `updatedAt` 降序排好 —— 协议规定客户端**不必自己排**。
///
/// **只有行**：分组来自 `workspace/follow`（见 `WorkspaceStream`），不在这一条应答里。
/// 一份应答给两样东西，就会出现「行是新的、组是旧的」那种中间态。
@MainActor
func fetchSessions(_ client: RpcClient) async throws -> [SessionSummary] {
    let response: ListSessionsResponse = try await client.perform(ListSessionsRequest())
    return response.items ?? []
}

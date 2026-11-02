/**
 * 会话列表的状态：取一次，把结果落成三种面 —— 有内容 / 前置不满足 / 真失败。
 *
 * 只回答「取回来是什么」，**不回答「什么时候取」**：触发点归视图。唯一的例外是事件流的代次
 * （那是「恢复」这个事实本身）。失败不清空已有列表；前置不满足是 `blocked` 而非 `failed`。
 */
import Foundation

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
    /// 宿主的工作空间清单，顺序即显示顺序。只在拉取成功时更新 —— 组的成员或标题在
    /// 别的设备上改了，要等一次刷新才看到（组关系没有自己的订阅通道）。
    private(set) var workspaces: [WorkspaceSummary] = []
    private(set) var isLoading = false
    /// 正在让宿主建一个空会话。视图用它禁用入口 —— 连发两次只会让两个动作抢同一行状态。
    private(set) var isCreating = false
    /// 正在让宿主造一个工作空间。
    private(set) var isCreatingWorkspace = false
    /// 上一次创建工作空间的结果；`nil` 表示这次还没发起过。视图据它给提示 ——
    /// 结果留在这里而不是交回调用方，视图才不必接 `await` 的返回值。
    private(set) var workspaceCreation: WorkspaceCreation?
    /// 上一次提交被名字规则拒掉的理由。**判断在这里，不在视图**：视图里那句
    /// `if problem != nil { return }` 删掉不会有任何判据变红，而它守的正是 spec 的
    /// 「非法名字一个请求都不发」。
    private(set) var workspaceNameProblem: WorkspaceName.Problem?
    private(set) var outcome: Outcome = .ready

    /// 取一次列表。收成闭包是为了让「在途期间发生了什么」可被断言 ——
    /// 走真网络时，「两次请求并发」与「一次请求很慢」在测试里长得一样。
    private let fetch: () async throws -> SessionListPage
    /// 让宿主建一个空会话、交回 id。与 `fetch` 一样注入：新建的失败面要能被断言，
    /// 而走真网络时「宿主拒绝」与「网络断了」在测试里长得一样。
    ///
    /// 参数是落在哪个工作空间；`nil` 表示不指定（宿主用它自己的当前目录）。
    private let create: (String?) async throws -> String
    /// 让宿主造一个工作空间。同样注入，理由同上。
    private let createWorkspaceAction: (String) async throws -> WorkspaceCreated
    /// 建好之后去哪 —— 由装配段给（它握着导航栈）。**不叫 `navigate`**：这一层不认识
    /// `Destination` 那张路由表，它只知道「拿这个 id 去看那一条会话」。
    private let open: (String) -> Void
    /// 在途的那一次。单飞的落点，也是这批账的归属。
    private var inflight: Task<SessionListPage, Error>?
    /// 这一次在途期间到达的变更，按到达顺序。进 `reload` 时必然为空 —— `apply` 只在
    /// `inflight != nil` 时入账，而它只在 `reload` 体内非 nil。
    private var buffered: [SessionListChange] = []
    /// 是否已经听过事件流（`attach` 幂等）。
    private var attached = false
    init(fetch: @escaping () async throws -> SessionListPage,
         create: @escaping (String?) async throws -> String,
         createWorkspace: @escaping (String) async throws -> WorkspaceCreated,
         open: @escaping (String) -> Void) {
        self.fetch = fetch
        self.create = create
        self.createWorkspaceAction = createWorkspace
        self.open = open
    }

    convenience init(client: RpcClient, open: @escaping (String) -> Void) {
        self.init(fetch: { try await fetchSessions(client) },
                  create: { try await createBlankSession(client, in: $0) },
                  createWorkspace: { try await makeWorkspace(client, name: $0) },
                  open: open)
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


    /// 听事件流。这条流不重放，所以「两次报到之间的事件」可能已经丢了 —— 报到这里是它在
    /// 客户端唯一可观察的形式。幂等：视图重复出现时不该注册第二个听众。
    func attach(events: EventStream) {
        guard !attached else { return }
        attached = true
        // 两件都接：逐条的增量（改一行），与每一次报到（重拉基线）。少接一条的症状是
        // 「列表不自己动」或「断线之后再也不对齐」—— 都不编译失败。
        // 增量的解释在这里：挖 `change`、解形状、认不出丢弃。
        events.onCargo("session-list") { [weak self] payload in
            guard let change = payload["change"].flatMap(SessionListChange.decode) else {
                Log.warn(Log.Module.session,
                         "dropped a session-list change this build does not know")
                return
            }
            self?.apply(change)
        }
        events.onGeneration { [weak self] _ in
            Task { await self?.reload() }
        }
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
    ///   调用方拿它决定要不要再试一轮（见 `reloadAfterCreate`）。
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
            let page = try await task.value
            // 先摆响应的顺序，再把这批账依次重放 —— 反过来会让事件带来的位置被响应冲掉。
            var merged = visible(page.sessions)
            for change in buffered { merged = SessionListMerger.apply(change, to: merged) }
            // 重放会把事件推来的行加回去，所以落地之后再筛一次 —— 只筛一次的话，在途
            // 期间到达的 blank / subagent 会从这里漏进列表。
            sessions = visible(merged)
            // 组清单只跟应答走：它没有自己的增量通道，事件也不携带它。
            workspaces = page.workspaces
            outcome = .ready
        } catch {
            // 列表保留（事件带来的变化已经生效），只换失败面。
            //
            // 分类只看错误的类型，**不去推算「现在缺什么」**：`FailureText` 已经把两种前置
            // 说成了两句不同的话（组网未就绪 / 还没有配对），端上再猜一遍就会有两个说法。
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

    /// 造一个工作空间。成功（新建或本已存在）都重拉一次列表：
    /// 组清单只在拉取时更新，不重拉新组不会出现。
    ///
    /// 新建成功时**先就地插到最前**再重拉：宿主把新建的排在注册表首位，而 `reload` 撞在
    /// 一次在途请求上时只等不重发（那是它的单飞语义）。没有这一步，界面说「建好了」而
    /// 列表里没有那个组。
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
            if made.created {
                workspaces.insert(WorkspaceSummary(id: made.workspaceId, title: made.title), at: 0)
            }
            await reloadAfterCreate()
        } catch {
            workspaceCreation = .failed(error.localizedDescription)
        }
    }

    /// 建完之后取一次**新**的列表。
    ///
    /// 不能直接 `reload()`：它在有在途请求时只等不重发，而在途那次的结果早于这次创建 ——
    /// 等它就等于把旧快照当最新，界面说「建好了」而列表里没有那个组。
    ///
    /// 所以每轮都问一句「这一发真的发出去了吗」，没发出去就让一轮步再试；上限三轮。
    /// 在途那次的 body 从拿到值之后到收尾之间没有 `await`，因此一轮让步通常就够 ——
    /// 上限只是防它永远不让位。
    ///
    /// 上面那一步「就地插到最前」是同一件事的另一半：万一三轮都没发出，列表至少已经能
    /// 看到新组。
    private func reloadAfterCreate() async {
        for _ in 0..<3 {
            if await reload() { return }
            await Task.yield()
        }
    }

    /// 打开输入面板时清掉上一次的结果与拒绝理由 —— 否则「已经有了」会一直挂在那儿。
    func beginNamingWorkspace() {
        workspaceCreation = nil
        workspaceNameProblem = nil
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

/// 一次拉取得到的两样东西：会话行，与工作空间清单。
///
/// 合成一个类型而不是两个闭包：它们出自同一条应答、同一次读取，分开取就会有一个
/// 「行是新的、组清单是旧的」的中间态。只有一个消费者（列表状态），所以与它同住。
struct SessionListPage: Equatable {
    let sessions: [SessionSummary]
    let workspaces: [WorkspaceSummary]
}

/// 拉会话列表。服务端已按 `updatedAt` 降序排好 —— 协议规定客户端**不必自己排**。
@MainActor
func fetchSessions(_ client: RpcClient) async throws -> SessionListPage {
    let response: ListSessionsResponse = try await client.perform(ListSessionsRequest())
    // clock 采样：服务端时钟与本地收到时刻的一对。两端 offset 由这一对估出来，
    // 才能修正跨机的 t3 段与端到端 —— 直接相减会把这个 offset 算进延迟里。
    // 采样点在这里而不是更上层：`serverTime` 只出现在这个回包里，而「收到的时刻」
    if let serverTime = response.serverTime {
        Log.perf(Log.Module.gateway, PerfRecord(
            seg: .clock, t: PerfRecord.nowMs(),
            fields: ["serverTime": .number(serverTime)]
        ))
    }
    // 组清单缺席（只读装配）与空数组在界面上同义：都表现为「全在未分组」。
    return SessionListPage(sessions: response.sessions ?? [],
                           workspaces: response.workspaces ?? [])
}

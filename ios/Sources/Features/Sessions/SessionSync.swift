import Combine
import Foundation

/// 一个会话的同步编排：把「取窗口 / 追新增 / 往回翻」三件事接到状态机上。
///
/// 状态机（`SessionMirror`）只管判定，这里管调用顺序与失败收场，界面只管显示。
/// 三处纪律落在这里：
/// - **单飞**：同一会话同时只有一个同步过程（`isSyncing`）。
/// - **拉完为止**：追新增时一块装不下就接着要，直到服务端说没有更多。
/// - **先窗口后增量**：打开会话必须先向服务端要一个最新的窗口，再从这里往后追 ——
///   这样**不需要跨会话记住任何位置**，冷启动、重启、跑了一夜回来，行为都一样。
///
/// 镜像只在内存里（见 `SessionMirror` 的说明）：没有任何位置或内容落盘。
///
/// 用 `ObservableObject` 而不是更新的 `@Observable` 宏：后者要跑一个进程外的宏插件，
/// 而本项目的验证环境不允许 —— **能被本地编译验证，比写法新更重要**。
@MainActor
final class SessionSync: ObservableObject {

    /// 状态行要说的事。**重置与失败必须说得出来** —— 那是用户唯一能察觉异常的地方。
    enum Status: Equatable {
        case idle
        case syncing
        case done(added: Int, recovered: Bool)
        case failed(String)
    }

    /// 屏幕上要画的消息。
    @Published private(set) var messages: [DisplayMessage] = []
    /// 屏幕上要画的东西 —— 消息**与过程**（M6）：一轮的工具调用与思考折进一行，
    /// 最终答案留在原位。由组装器从同一批事件算出来（判据 A1–A9）。
    @Published private(set) var nodes: [TranscriptNode] = []
    /// 视图里的事件条数（消息只是其中一部分）。
    @Published private(set) var eventCount = 0
    /// 还能往回翻吗。为真时界面给出入口。
    @Published private(set) var hasOlder = false
    @Published private(set) var status: Status = .idle
    /// 正在生成的回复（打字机）；没有进行中的 attempt 就是空串。
    @Published private(set) var transientText = ""
    /// 跟随流的连接阶段 —— 连接态指示器的数据源（M3），从 `FollowClient` 转发。
    @Published private(set) var connectionPhase: FollowClient.Phase = .idle
    /// 上下文占用（M6）。为 `nil` 时界面**隐藏整行** —— 「没有读数」与「占用 0%」
    /// 不是一回事，那个区别整个 M6 的占用链路都在守（判据 U2）。
    @Published private(set) var usage: UsagePayload? = nil

    private let client: GatewayClient
    private let sessionId: String
    /// 待批审批的状态机（M5）。事实来源与镜像同一条：窗口事件里的
    /// `approval/asked` − `approval/decided` 差集，在每次刷新视图时重建。
    let approvals: ApprovalStore
    /// 内存里的镜像。视图重建时会新建一个 `SessionSync`，于是窗口重取一次 ——
    /// 这是刻意的：窗口是服务端此刻给的，比任何本地残留都可信。
    private var mirror = SessionMirror()
    private var isSyncing = false

    /// 跟随流（M2）：打开详情页即开启，实时收 opening / 事件 / 瞬态帧。
    private lazy var follow: FollowClient = {
        let followClient = FollowClient()
        followClient.onOpening = { [weak self] payload in self?.applyOpening(payload) }
        followClient.onEvent = { [weak self] event in self?.applyLiveEvent(event) }
        followClient.onTransient = { [weak self] frame in self?.applyTransient(frame) }
        followClient.onApproval = { [weak self] payload in self?.approvals.receive(payload) }
        followClient.onUsage = { [weak self] snapshot in self?.applyUsage(snapshot) }
        followClient.onRefused = { [weak self] failure in self?.handleStreamRefusal(failure) }
        // 连接态指示器的唯一来源（M3）：`FollowClient` 改了阶段就转发过来，界面直读
        // `connectionPhase`。不接的话指示器永远停在 idle、`ConnectionBadge` 恒隐藏。
        followClient.onPhaseChange = { [weak self] phase in self?.connectionPhase = phase }
        // M4：upgrade 时刻取一张有效的 access —— 没有就裸连，让服务端如实拒绝。
        followClient.authorizationProvider = { CredentialStore.shared.validAccessToken() }
        return followClient
    }()
    private var transient = TransientChannel()
    /// 事件 → 显示节点（M6）。唯一的状态是「已上报过哪些不认识的类型」，
    /// 所以它跨刷新保留：每次刷新都重放整段窗口，不去重就会刷屏。
    private var assembler = TranscriptAssembler { type in
        // 上游加了新的事件类型 —— 会话照常显示，这里留一条痕。
        print("[TranscriptAssembler] 不认识的事件类型：\(type)")
    }
    /// 占用值的吸收（M6）。判定（严格高水位胜）全在值类型里（判据 O1），
    /// 这里只持有它、把采纳的结果转发给视图。
    private var usageState = UsageState()
    /// 把嵌套状态机的变化冒泡成自己的 objectWillChange：视图只观察
    /// `SessionSync`，而 `ApprovalStore` 是独立的 ObservableObject ——
    /// 不转发的话，审批卡的增删根本不会触发视图重算（真机踩实）。
    private var approvalsObservation: AnyCancellable?

    init(client: GatewayClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
        self.approvals = ApprovalStore(client: client)
        approvalsObservation = approvals.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// 下发一条指令（M5）：回包 ok = 已受理，回答本身从跟随流里来。
    /// 失败如实进状态行 —— 发送失败时输入的字还在框里，用户可以重试。
    func sendPrompt(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await client.sendPrompt(sessionId: sessionId, text: trimmed, promptId: UUID().uuidString)
        } catch {
            status = .failed("指令没能送达：\(error.localizedDescription)")
            refreshView()
        }
    }

    /// 同步一次：镜像空着就先取一个窗口，然后从末尾追新增到最新。
    ///
    /// 幂等 —— 已经是最新时它退化成一次空增量请求，这正是它的正常形态。
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        status = .syncing

        var added = 0
        var recovered = false

        // 打开会话：手里什么都没有时，先向服务端要一个最新的窗口。
        if mirror.isEmpty {
            switch await openLatest() {
            case .merged(let count):
                added += count
            case .caughtUp:
                break
            case .resetRequired:
                // 窗口本身对不上，没有比它更早的状态可退。
                mirror.reset()
                recovered = true
            case .refused(let code):
                status = .failed("服务端拒绝了这次读取：\(code)")
                refreshView()
                return
            case .failed:
                status = .failed("没连上网关 —— 这一屏还是空的。")
                refreshView()
                return
            }
        }

        // 追新增：从镜像的末尾一直拉到服务端没有更多。
        while true {
            guard mirror.beginRequest() else { break }
            let outcome = await fetchSnapshot()
            let more = hasMore(in: outcome)

            switch mirror.apply(outcome) {
            case .merged(let count):
                added += count

            case .caughtUp:
                break

            case .resetRequired(let reason):
                // 重置只做一次：若重置之后服务端又要求重置，那说明继续拉也不会收敛，
                // 停下来把情况说清楚，比无限重试好。
                guard !recovered else {
                    status = .failed("服务端连续要求重新同步（\(label(reason))）—— 已停止重试。")
                    refreshView()
                    return
                }
                recovered = true
                mirror.reset()
                // 位置已作废，没有内容可续。下一次同步会以「取窗口」的形态重来。
                status = .done(added: added, recovered: true)
                refreshView()
                return

            case .refused(let code):
                status = .failed("服务端拒绝了这次同步：\(code)")
                refreshView()
                return

            case .failed:
                // 传输失败：视图保持原样（状态机保证），只把状态说清楚。
                status = .failed("没连上网关 —— 手机上看到的仍是上一次同步的内容。")
                refreshView()
                return
            }

            if !more { break }
        }

        status = .done(added: added, recovered: recovered)
        refreshView()
    }

    /// 往回翻一段更早的历史。已经翻到日志开头时什么也不做。
    func loadOlder() async {
        guard !isSyncing, mirror.hasOlder else { return }
        isSyncing = true
        defer { isSyncing = false }
        status = .syncing

        guard mirror.beginRequest() else { return }

        let verdict: Verdict
        do {
            let page = try await client.page(sessionId: sessionId, beforeSeq: mirror.pageStart)
            verdict = mirror.prepend(window(page))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error {
                verdict = .refused(code: failure.code)
            } else {
                verdict = .failed
            }
        } catch {
            verdict = .failed
        }

        switch verdict {
        case .merged(let count):
            status = .done(added: count, recovered: false)
        case .caughtUp:
            status = .done(added: 0, recovered: false)
        case .resetRequired:
            // 这一段接不上当前视图的起点 —— 与其留一个看不见的缺口，不如清空重来。
            mirror.reset()
            status = .failed("更早的历史接不上这一段 —— 已清空，下拉可重新同步。")
        case .refused(let code):
            status = .failed("服务端拒绝了这次读取：\(code)")
        case .failed:
            status = .failed("没连上网关 —— 未能加载更早的消息。")
        }

        refreshView()
    }

    // MARK: - 跟随（M2 的主路径）

    /// 打开详情页即跟随：服务端推 opening（首屏窗口）与后续事件，不再轮询。
    ///
    /// 编排只做两件事，判定全在状态机里 —— 与 HTTP 路径共用同一台 `SessionMirror`：
    /// - opening → `mirror.open(with:)`（**替换**窗口，重连重建同此一途）
    /// - 事件帧 → `mirror.apply(.received(Snapshot(asOfSeq: seq + 1, …)))`
    ///   —— 一条事件就是一次「覆盖到 seq+1 的快照」，幂等与缺口判定原样生效。
    func startFollowing() {
        follow.start(sessionId: sessionId)
    }

    /// 离开详情页：关流、清瞬态。镜像留在内存里（视图销毁时一起消失）。
    func stopFollowing() {
        follow.stop()
        transient = TransientChannel()
        transientText = ""
    }

    /// 回前台立即触发重连（M3）：上游「恢复立即试」的复现。已就绪或正在握手时无事发生。
    /// 只动连接编排，不碰镜像 —— 新 opening 会经 `applyOpening` 原路进来。
    func reconnectNow() {
        follow.reconnectNow()
    }

    private func applyOpening(_ payload: JSONValue) {
        let window = Window(
            pageStart: payload["pageStart"]?.int ?? 0,
            asOfSeq: payload["cursor"]?.int ?? 0,
            hasOlder: payload["hasOlder"]?.bool ?? false,
            events: (payload["events"]?.array ?? []).compactMap { try? JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode($0)) }
        )
        _ = mirror.open(with: window)

        // 瞬态基线：opening 里带了进行中的 attempt 就恢复打字机，没有就清场。
        if let baseline = payload["assistantStream"] {
            transient.apply(baseline: parseBaseline(baseline))
        } else {
            transient = TransientChannel()
        }
        transientText = transient.text
        status = .done(added: window.events.count, recovered: false)
        refreshView()
    }

    private func applyLiveEvent(_ event: SessionEvent) {
        // 一条事件 = 一次覆盖到 seq+1 的快照；无缺口可言（上游 gap-free 是契约，
        // 网关另有目击），幂等照旧生效。
        _ = mirror.apply(.received(Snapshot(asOfSeq: event.seq + 1, hasMore: false, events: [event])))
        refreshView()
    }

    private func applyTransient(_ frame: JSONValue) {
        let before = transient
        let verdict = transient.apply(frame: frame)
        if verdict == .broken {
            // 基线已丢，后续 chunk 是增量 —— 干等只会残缺，重开流取新基线。
            print("[TransientChannel] broken: expected revision=\(String(describing: before.expectedRevisionDescription)) nextChunkIndex=\(before.nextIndexDescription), got type=\(frame["type"]?.string ?? "?") revision=\(String(describing: frame["revision"]?.int)) index=\(String(describing: frame["index"]?.int))")
            follow.reopenStream()
            return
        }
        transientText = transient.text
    }

    private func handleStreamRefusal(_ failure: GatewayFailure) {
        status = .failed("跟随流被拒绝：\(failure.readableDescription)")
        refreshView()
    }

    /// 一份占用读数（M6）：opening 里的基线，或后续 `usage` 帧 —— 同一处理。
    ///
    /// 被丢弃的帧**不动视图**（`UsageState` 判定的），所以乱序与重放不会让
    /// 百分比跳一下再回来。
    private func applyUsage(_ snapshot: UsageSnapshot) {
        guard usageState.apply(snapshot) == .accepted else { return }
        usage = usageState.usage
    }

    /// opening 的瞬态基线 → 通道的输入。只认我们声明的字段，其余忽略。
    private func parseBaseline(_ json: JSONValue) -> TransientBaseline {
        let active = json["activeAttempt"]
        return TransientBaseline(
            revision: json["revision"]?.int ?? 0,
            active: active == nil ? nil : TransientBaseline.Active(
                nextIndex: active?["nextIndex"]?.int ?? 0,
                stream: active?["stream"]?.array ?? []
            )
        )
    }

    // MARK: - 一次请求

    /// 取最新的一个窗口（打开会话）。
    private func openLatest() async -> Verdict {
        guard mirror.beginRequest() else { return .caughtUp }
        do {
            let page = try await client.page(sessionId: sessionId)
            return mirror.open(with: window(page))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error { return .refused(code: failure.code) }
            return .failed
        } catch {
            return .failed
        }
    }

    /// 从镜像的末尾往前拉一块。
    private func fetchSnapshot() async -> Outcome {
        do {
            let snapshot = try await client.snapshot(sessionId: sessionId, since: mirror.cursor)
            return .received(Snapshot(
                asOfSeq: snapshot.asOfSeq,
                hasMore: snapshot.hasMore,
                events: snapshot.events
            ))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error {
                return .refused(Refusal(code: failure.code, message: failure.message))
            }
            return .transportFailed
        } catch {
            return .transportFailed
        }
    }

    private func hasMore(in outcome: Outcome) -> Bool {
        if case .received(let snapshot) = outcome { return snapshot.hasMore }
        return false
    }

    /// 网络层的窗口 → 状态机的窗口。两者形状相同：一个是「服务端的回应」，
    /// 一个是「状态机的输入」，各自跟着自己的层走。
    private func window(_ page: SessionPage) -> Window {
        Window(
            pageStart: page.pageStart,
            asOfSeq: page.asOfSeq,
            hasOlder: page.hasOlder,
            events: page.events
        )
    }

    /// 刷新界面可见的部分。状态机是唯一的事实来源。
    ///
    /// 组装每次都从**整段事件**重算，不做增量：窗口是几十到几百条，重算的代价
    /// 远低于「增量组装写错一处就静默少一行」的风险（往回翻会前插内容，增量
    /// 还得处理插入位置）。真机上窗口大到手感有变化时再谈（登记在 §8.5）。
    private func refreshView() {
        messages = mirror.events.compactMap(\.displayMessage)
        nodes = assembler.assemble(mirror.events)
        eventCount = mirror.events.count
        hasOlder = mirror.hasOlder
        approvals.rebuild(from: mirror.events)
    }

    /// 重置理由的人话说法。这类文案属于界面，不属于状态机。
    private func label(_ reason: ResetReason) -> String {
        switch reason {
        case .gap: return "中间有事件没拿到"
        case .waterMarkWentBack: return "服务端给的位置比本地还靠前"
        case .cursorVoid: return "本地记的位置在 Mac 上不存在了"
        }
    }
}

extension SessionSync.Status {
    /// 状态行的一句话。
    var line: String {
        switch self {
        case .idle:
            return "尚未同步"
        case .syncing:
            return "正在同步…"
        case .done(let added, let recovered):
            let prefix = recovered ? "已重新同步" : "已是最新"
            return added == 0 ? prefix : "\(prefix)，新增 \(added) 条"
        case .failed(let detail):
            return detail
        }
    }
}

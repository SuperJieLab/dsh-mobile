/**
 * TailscaleKit 的包装层：节点生命周期 → `TailnetNodeState` 事件。
 *
 * 只做「上游调用 + 结果归类成状态机事件」，迁移决策全在纯状态机。注册成功的副产物是一只
 * 走 SOCKS5 回环的 `gatewaySession`，由 `MeshStore` 收成 `route`。
 * 上游类型只在 `TailnetBackend` 出现，本文件只认那条窄面。
 */
import Foundation

@MainActor
@Observable
final class TailnetNode {

    /// 票的可核对形式：头 11 位 + 尾 6 位，够对上 headscale 的 auth id，又不整串刷屏。
    private static func ticketHint(_ ticket: String?) -> String {
        guard let ticket else { return "nil" }
        guard !ticket.isEmpty else { return "<empty>" }
        guard ticket.count > 20 else { return "<short:\(ticket.count)>" }
        return "\(ticket.prefix(11))…\(ticket.suffix(6))"
    }

    /// 状态机当前状态（界面据此渲染；迁移判定全在 `TailnetNodeState.handle`）。
    private(set) var state: TailnetNodeState = .noIdentity

    /// 起节点那段（`up()`）还在跑。**与 `state` 是两件事**：状态目录健康时 `launch` 一上来
    /// 就是 `.running`，而真正的接入还要跑最长约 49 秒。设置页与 `revive()` 都据此避让。
    private(set) var isStarting = false

    /// 每一代接入的代号。被取代一次 +1；`up()` 把当代代号带进循环，**每个写状态的点前先判
    /// 「我是不是当代」**。漏判一处，迟到的结论就会静默改写新一代的结果。
    private var generation = 0

    /// 一次 `close()` 最多等多久。上游的 close 是唯一取消手段，但它自己不保证时限 ——
    /// 没有上限时，「打断」只是把 45 秒的等待换成一次时长未知的等待。
    private static let closeWaitLimitSeconds: TimeInterval = 2

    /// Running 后可用：全部流量进 tailnet 的 session，由 `MeshStore` 取走交给端点层。
    private var gatewaySession: URLSession?

    /// 当前到网关对端的路径：Running 期间轮询刷新，其余为 nil。
    private(set) var meshPath: CarrierPath?

    /// 节点验证 Running、tailnet session 建成的那一刻（同值迁移不触发 onChange）。
    var onVerifiedRunning: ((URLSession) -> Void)?

    /// 对外可见事实变化的推送通道（状态迁移与路径刷新处调用），连接域是唯一消费者。
    var onNodeChanged: (() -> Void)?

    /// 造后端那一步：默认造真件，测试注入假件（`isStarting` 是 `private(set)`，外部设不进去）。
    private let makeBackend: BackendFactory

    private var node: (any TailnetBackend)?
    private var pathPollTask: Task<Void, Never>?

    /// 「本机有没有节点身份」的探测。做成可注入：判据要能造「有身份 / 没身份」两种世界，
    /// 而不必去动真实的 App 沙盒。
    private let identityProbe: @MainActor () -> Bool

    init(makeBackend: @escaping BackendFactory = TailnetBackends.live,
         identityProbe: @escaping @MainActor () -> Bool = { TailnetNode.stateStoreHealthy() }) {
        self.makeBackend = makeBackend
        self.identityProbe = identityProbe
    }

    // MARK: - 接入票（只在内存里活一次，从不落盘）

    /// 老版本把票写在沙盒里（`secrets/tailnet-key`）。本版不再存票，启动时删一次就够 ——
    /// 删一个不存在的文件是幂等的，不需要额外的版本标记。
    private static let legacyTicketFile = "tailnet-key"

    /// 用户刚贴、还没换出节点身份的那把票。
    ///
    /// **活到注册成功**：失败要留着，否则「重试」永远点不动（票没了、身份也没有）；
    /// 成功后立刻清（它已经无用）；进程被杀随之消失 —— 这正是「不落盘」的含义。
    private var pendingKey: String?

    // MARK: - 入口（App 启动 / 设置页动作）

    /// App 启动：读节点持久状态 → 状态机判定 → 需要则起节点。**不带票。**
    func launch(config: MeshConfig) async {
        // 老版本存过票：删一次。票从不参与启动 —— 它在注册成功那一刻就失去用途了。
        SecretFile.delete(Self.legacyTicketFile)
        let identity = identityProbe()
        let sameControlPlane = ControlPlaneRecord.matches(config.controlURL)
        Log.info(Log.Module.mesh,
                 "launch: identity=\(identity) controlPlaneMatches=\(sameControlPlane)"
                 + " controlURL=\(config.controlURL?.absoluteString ?? "<invalid>")"
                 + " gateway=\(config.gatewayURLString)")
        // 换了控制面：目录里那份身份属于上一家，留着只会让新节点「连上但通不了」。
        // 只在这条路上清 —— 目录读不了（半份本地文件）不清，上游自己会重建。
        if identity, !sameControlPlane {
            discardNodeState(from: "control plane changed")
        }
        transition(.launch(identityPresent: identity, controlPlaneMatches: sameControlPlane))

        switch state {
        case .running:
            // 幂等：二次 launch 会把旧 socket 全杀掉，socks5 / localapi 随即报 closed，
            // 路径标签也掉。
            // 已验证 Running 且 session 还在时不再 re-up。
            if let session = gatewaySession {
                Log.info(Log.Module.mesh, "launch: node already running with live session — skip re-up")
                onVerifiedRunning?(session)
                startPathPolling()
                return
            }
            // 不带票起：身份在，让上游用 node key 连。起不起来由 BackendState 说话 ——
            // 「目录健康」只是一个粗筛，它回答不了「已登录没有」。
            await up(ticket: pendingKey, config: config, generation: generation)
        default:
            break
        }
    }

    /// 设置页提交接入票：只进内存 → 注册 → 成功后丢弃。
    /// **不拒绝「节点正在起」**：用户给的是新地址，那次在跑的接入的结论已经不相关了，
    /// 正确处置是让老的作废（`beginSupersede()`），不是让用户等它跑完。
    func submitKey(_ key: String, config: MeshConfig) async {
        Log.info(Log.Module.mesh, "submitKey",
                 ["ticket": Self.ticketHint(key), "chars": String(key.count)])
        guard !key.isEmpty else {
            // 空提交不进状态机注册流程 —— 也**不**打断在跑的那一次：没有新地址要换。
            transition(.registrationFailed(.badKey))
            return
        }
        let gen = beginSupersede()
        // 存内存排在等待之前：close 可能耗到上限，这期间用户可能再提交一次，
        // 后提交的那一次才该是当下的。等完再存就会出现「先点的那次覆盖后点的」。
        pendingKey = key
        await closeSupersededNode(of: gen)
        // 等待期间被更新的一代取代：这一次提交的结论归它，这里一个字段都不写。
        guard gen == generation else { return }
        transition(.keySubmitted)
        await up(ticket: key, config: config, generation: gen)
    }

    /// failed 修复后的重试（换票 / 网络恢复）。
    ///
    /// 能不能试由两件事之一决定：**有身份**（用 node key 起），或**手里还留着这一进程的票**。
    /// 两者都没有就别打断在跑的那次，直接把话说明白 —— 重试一百次也不会成功。
    func retry(config: MeshConfig) async {
        let identity = identityProbe()
        let ticket = pendingKey
        Log.info(Log.Module.mesh, "retry", [
            "identity": String(identity),
            "ticket": Self.ticketHint(ticket),
        ])
        guard identity || ticket != nil else {
            transition(.retry(identityPresent: false, ticketPresent: false))
            return
        }
        let gen = beginSupersede()
        await closeSupersededNode(of: gen)
        guard gen == generation else { return }
        transition(.retry(identityPresent: identity, ticketPresent: ticket != nil))
        if case .registering = state {
            await up(ticket: ticket, config: config, generation: gen)
        }
    }

    /// 回前台的探活：只探测状态是否仍可读，读不了就落 `failed(unreachable)`，不自动重试。
    /// 起节点期间不探活：那时读 `statusJSON` 多半报错，会把正常接入打成失败，而 `.failed`
    /// 之后成功进不来。
    func revive() async {
        guard !isStarting else { return }
        guard case .running = state, let node else { return }
        do {
            _ = try await node.statusJSON()
            refreshPathNow()
        } catch {
            stopPathPolling()
            transition(.nodeUnreachable)
        }
    }

    // MARK: - 后端事实探测（闭合信号）

    /// 读 statusJSON 的 BackendState。字段名跟 `tailscale status --json` 走。
    private static func backendState(of node: (any TailnetBackend)?) async -> String? {
        guard let node,
              let data = try? await node.statusJSON(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["BackendState"] as? String
    }

    /// 轮询等后端到 Running：注册落库有滞后，短窗口内多看几次。
    ///
    /// 返回**最后一次读到的状态**而不是布尔：`NeedsLogin` 与 `NeedsMachineAuth` 都不算 Running，
    /// 但补救完全不同（一把新票 vs 等人批准）。折成布尔就把这条区别丢了。
    private static func settleBackendState(_ node: any TailnetBackend) async -> String? {
        var last: String?
        for _ in 0..<3 {
            last = await backendState(of: node)
            if last == "Running" { return last }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return last
    }

    // MARK: - 路径展示

    /// 读 tsnet status 的对端路径：对端带 `CurAddr` 即直连，只落在 `Relay` 上即中继。
    /// 读不出（挂起中、status 暂不可用）返回 nil —— 展示层对 nil 就不显示。
    private func pathKind() async -> CarrierPath? {
        guard let node else { return nil }
        let data: Data
        do { data = try await node.statusJSON() } catch { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // 字段名跟 tailscale status --json 走（Peer / CurAddr / Relay）；两代键名都认。
        let peers = (root["Peer"] as? [String: Any]) ?? (root["Peers"] as? [String: Any]) ?? [:]
        var relayed: CarrierPath?
        for case let peer as [String: Any] in peers.values {
            let curAddr = peer["CurAddr"] as? String ?? ""
            if !curAddr.isEmpty { return .direct }
            if !(peer["Relay"] as? String ?? "").isEmpty, relayed == nil { relayed = .relay }
        }
        return relayed
    }

    private func refreshPathNow() {
        Task { [weak self] in
            guard let self else { return }
            self.meshPath = await self.pathKind()
            self.onNodeChanged?()
        }
    }

    /// Running 期间按固定节奏轮询路径；掉出 Running 即停并清值。
    /// 轮询而非事件订阅：上游 statusJSON 是拉取式，验收靠同刻人工对照，15s 粒度够用。
    private func startPathPolling() {
        guard pathPollTask == nil else { return }
            pathPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if case .running = self.state {
                        // 顺带探测后端事实：显示 running 但后端掉回 NeedsLogin
                        //（key 被拒/被撤销）= UI 在说谎 → 如实落 failed。
                        if await Self.backendState(of: self.node) == "NeedsLogin" {
                            Log.info(Log.Module.mesh, "poll: backend fell to NeedsLogin while UI running → failed")
                            self.stopPathPolling()
                            self.transition(.nodeUnreachable)
                            continue
                        }
                        self.meshPath = await self.pathKind()
                        self.onNodeChanged?()
                    } else if self.meshPath != nil {
                        self.meshPath = nil
                        self.onNodeChanged?()
                    }
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
            }
    }

    private func stopPathPolling() {
        pathPollTask?.cancel()
        pathPollTask = nil
        if meshPath != nil {
            meshPath = nil
            onNodeChanged?()
        }
    }

    // MARK: - 节点起停（上游调用 + 事件归类）

    /// 一次尝试的上限。上游 `tailscale_up` 没有超时，连不上控制面时一直等；
    /// 没有上限，界面永远停在「注册中」，既看不到失败也拿不到重试入口。
    private static let upTimeoutSeconds: TimeInterval = 15

    /// 一次启动最多试几回；地址写错时无限重试只是把静态错误变成一串噪音。
    private static let upAttemptLimit = 3

    /// 两次尝试之间的下限。组网启动本身要几秒，立即重试只是把同一次失败再问一遍。
    private static let upRetryFloorMs = 2_000

    /// 一次尝试的结果 —— 归因决定要不要再试：环境问题值得，key 被拒只会消耗限次。
    private enum UpOutcome {
        /// 后端验证 Running，并交出了这一代的隧道产物（由调用方决定收不收）。
        case ready(URLSession)
        case retryable(TailnetNodeFailure)
        case fatal(TailnetNodeFailure)
    }

    /// 让在跑的那一代立刻作废：**同步**，返回之后旧一代的任何写入都不会落地。
    ///
    /// 与收尸（`closeSupersededNode`）分开，是因为调用方需要它「立刻」生效 —— 提交新配置时，
    /// 新地址会先写进组网配置；若作废要等一个 `await`，那之间旧一代的成功回调就会把
    /// **旧 session** 与**新地址**拼成一对，请求于是全打在那边到不了的地方且不报错。
    /// 同步做完这一半，那一对在时间上就拼不出来（调用链在同一 actor 上，中间没有挂起点）。
    ///
    /// **返回新代号，由调用方带进 `up()`。** 不能让 `up()` 自己在入口读 `generation`：读的是
    /// 那一刻的值，而 close 可能挂住一两秒 —— 这期间再来一次提交，两次都会读到最后一个值，
    /// 于是两代并到同一个代号上，各自都能交产物、都能写状态。
    ///
    /// 顺序也有讲究：先 `generation += 1`，再把状态交回「接入中」——
    /// `MeshStore.route` 的守卫读状态，不离开 `.running` 就还会返回那个已关闭节点的会话。
    @discardableResult
    private func beginSupersede() -> Int {
        generation += 1
        transition(.superseded)
        return generation
    }

    /// 关掉这一代作废的那个节点并清掉它的产物。可能耗到上限，所以必须在作废之后单独等。
    ///
    /// **只在仍是当代时清**：等待期间可能已被更新的一代取代，那时清场归后一代 ——
    /// 它要关的是同一个 `node`，这一代再去清只会把后一代刚建好的东西抹掉。
    private func closeSupersededNode(of generation: Int) async {
        if let node {
            await Self.close(node, within: Self.closeWaitLimitSeconds)
        }
        guard generation == self.generation else { return }
        node = nil
        gatewaySession = nil
        stopPathPolling()
    }

    /// 等 `close()` 收尾，但只等到上限 —— 上游的 close 自己不保证会返回。
    /// 到点仍然放手：代际已经 +1，这一代无论如何都作废，不差它有没有真的关干净。
    ///
    /// **不能写成 `withTaskGroup`**：那个 scope 退出时要等所有子任务结束，而挂住的 `close()`
    /// 不响应取消 ⇒ 上限形同虚设，调用方照样无限期等。这里用「谁先到就用谁 resume 一次」，
    /// 另一个任务不再被等待。
    private static func close(_ node: any TailnetBackend, within seconds: TimeInterval) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                try? await node.close()
                if once.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { continuation.resume() }
            }
        }
    }

    /// 两条路争着 resume 同一个 continuation —— 只许成功一次。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !used else { return false }
            used = true
            return true
        }

        /// 已经被别人认领 —— 轮询那条路据此收工，不必跑到超时。
        var isUsed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return used
        }
    }

    /// 起一代节点并等登录完成；环境类失败自动重试。
    ///
    /// `ticket` 为空 = 用本机的节点身份起（有身份时上游会直接忽略票，所以「不带票」是常态）。
    /// **只有「保存并接入」那一次会带票**，成功之后它立刻被丢掉。
    ///
    /// **同代才写**：代号由提交方带进来（`beginSupersede()` 的返回值），循环每轮与每个写状态
    /// 的点前都比一次 —— 被取代之后这一代什么都不写，也不清 `isStarting`（那是新一代的窗口）。
    private func up(ticket: String?, config: MeshConfig, generation current: Int) async {
        isStarting = true
        defer { if current == generation { isStarting = false } }

        var attempt = 0
        while true {
            // 被取代：立刻收场，一个字段都不写。
            guard current == generation else {
                Log.info(Log.Module.mesh,
                         "up: generation \(current) superseded — discarding this attempt")
                return
            }
            attempt += 1
            switch await attemptUp(ticket: ticket, config: config, generation: current) {
            case .ready(let session):
                guard current == generation else { return }
                gatewaySession = session
                // **先交产物、再宣布就绪**：`transition` 会立刻把「Running」推给上层，
                // 产物若还没交出去，上层看到的就是「已就绪、手上却还是上一代那个会话」——
                // 于是它先用旧会话连一次，紧接着被告知该换代，白连。
                // 顺序调过来，「就绪」这个词才名副其实：看到 Running 时产物已经在那儿了。
                // 也正因为状态那条通知**不带 session**，产物只能从这条回调交出去。
                onVerifiedRunning?(session)
                // 记下这一家用的是哪家控制面 —— 下一次启动靠它认出「身份是谁的」。
                // 排在 transition 之前：就绪一旦宣布，下一次 launch 就可能已经开始了。
                ControlPlaneRecord.save(config.controlURL)
                // 票的使命到此结束：身份已经在本地了，留着它只会制造「它还有效吗」这个问题。
                pendingKey = nil
                transition(.registrationSucceeded)
                startPathPolling()
                return

            case .fatal(let failure):
                guard current == generation else { return }
                Log.info(Log.Module.mesh, "up: not retrying, it cannot change",
                         ["failure": String(describing: failure)])
                finishFailed(failure)
                return

            case .retryable(let failure):
                guard attempt < Self.upAttemptLimit else {
                    guard current == generation else { return }
                    Log.info(Log.Module.mesh,
                             "up: giving up after \(attempt) attempts (\(failure))")
                    finishFailed(failure)
                    return
                }
                let delay = max(Self.upRetryFloorMs,
                                Backoff.delayMs(attempt: attempt,
                                                random: Double.random(in: 0..<1)))
                Log.info(Log.Module.mesh,
                         "up: attempt \(attempt)/\(Self.upAttemptLimit) failed (\(failure))"
                         + " — retrying in \(delay)ms")
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
        }
    }

    /// 一次尝试：造节点 → 等 up（带超时）→ 确认后端真的 Running。
    /// 不在这里迁移状态：重试期间停在 `registering`，迁移只在终局做。
    ///
    /// `self.node` 的写入也要过代际判据：`runUp` 最长 15 秒，这期间换代完全可能发生，
    /// 而句柄是**当代**的东西 —— 旧一代超时后把它抹成 nil，今天的活节点就没人关得掉了
    /// （`revive()` 直接返回、路径轮询恒 nil、下一次 `closeSupersededNode` 也够不着它）。
    private func attemptUp(ticket: String?, config: MeshConfig,
                           generation current: Int) async -> UpOutcome {
        guard config.isComplete, let controlURL = config.controlURL else {
            // 配置没填全（实际只可能是网关地址缺）：视同不可达（界面提示去设置页补地址）。
            // 重试不会补上地址。
            Log.info(Log.Module.mesh, "up: config incomplete → unreachable")
            return .fatal(.unreachable)
        }
        Log.info(Log.Module.mesh,
                 "up: start hostname=dsh-iphone controlURL=\(controlURL.absoluteString)"
                 + " ticket=\(Self.ticketHint(ticket))")

        let node: any TailnetBackend
        do {
            node = try makeBackend(
                TailnetBackendSpec(
                    hostName: "dsh-iphone",
                    stateDir: Self.stateDir.path,
                    authKey: ticket,
                    controlURL: controlURL.absoluteString
                )
            )
        } catch {
            let message = String(describing: error)
            Log.info(Log.Module.mesh, "up: init threw", ["error": message])
            return Self.outcome(forMessage: message)
        }
        // 到这一行没有挂起点（造后端是同步的），所以循环开头那次代际判定仍然成立。
        self.node = node

        switch await Self.runUp(node) {
        case .timedOut:
            Log.info(Log.Module.mesh,
                     "up: no answer in \(Int(Self.upTimeoutSeconds))s"
                     + " — closing this node (upstream has no timeout of its own)")
            // `close` 是上游指定的取消手段：它让卡住的 `up()` 收尾，不留一条还在跑的 Go 侧节点。
            // 它关的是**这一次尝试造的**那个，与代际无关，所以无条件关。
            try? await node.close()
            if current == generation { self.node = nil }
            return .retryable(.unreachable)

        case .failed(let message):
            Log.info(Log.Module.mesh, "up: threw", ["error": message])
            if current == generation { self.node = nil }
            return Self.outcome(forMessage: message)

        case .settled(let settledState):
            // 状态已经定了，不必再等 `up()` 返回（它可能在等一个没人会点的授权链接）。
            Log.info(Log.Module.mesh,
                     "up: backend settled before up() returned", ["state": settledState])
            try? await node.close()
            if current == generation { self.node = nil }
            return Self.failure(forBackendState: settledState, ticket: ticket)

        case .returned:
            // 闭合信号：up() 返回 ≠ 注册完成（停在 NeedsLogin 时它也返回）。
            // 判据只看上游报告的状态，不再拿「有没有票」去猜。
            let backendNow = await Self.settleBackendState(node)
            Log.info(Log.Module.mesh,
                     "up: returned, BackendState=\(backendNow ?? "<unreadable>")")
            if backendNow == "Running" {
                Log.info(Log.Module.mesh, "up: verified Running")
                do {
                    // 产物交给调用方收 —— 写入口集中在 `up`，代际判据也就只在那里判一次。
                    return .ready(try await node.makeGatewaySession())
                } catch {
                    Log.info(Log.Module.mesh,
                             "up: session build threw \(String(describing: error))")
                    self.node = nil
                    return .retryable(.unreachable)
                }
            }
            if let backendNow {
                return Self.failure(forBackendState: backendNow, ticket: ticket)
            }
            // 读不出状态：连「起没起来」都问不到，按环境问题处理。
            Log.info(Log.Module.mesh, "up: NOT Running and state unreadable")
            return .retryable(.unreachable)
        }
    }

    /// 跑一次 `up()`，到点就放弃；超时那一支由调用方 `close` 收尾（取消 Task 中断不了 Go 侧等待）。
    private enum UpStep: Sendable {
        case returned
        case failed(String)
        case timedOut
        /// 上游已经给出终局状态（未登录 / 等批准），不必再等 `up()` 返回。
        case settled(String)
    }

    private static func runUp(_ node: any TailnetBackend) async -> UpStep {
        // 三件事争一个结论：`up()` 返回、到点、状态先露出终局。
        // **不能用 `withTaskGroup`**：那个 scope 退出时要等所有子任务结束，而挂住的 `up()`
        // 不响应取消 —— 于是一个「等到终局就收」的分支反而会被它拖住（与 `close` 同一个坑）。
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UpStep, Never>) in
            Task {
                let step: UpStep
                do {
                    try await node.up()
                    step = .returned
                } catch {
                    step = .failed(String(describing: error))
                }
                if once.claim() { continuation.resume(returning: step) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(upTimeoutSeconds * 1_000_000_000))
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
            // 未登录时上游会转成交互式登录并**挂住**，等人在浏览器里点。手机上没这条流程，
            // 干等就是把超时耗尽、最后还归错因；状态一露终局就主动收。
            Task {
                let ticks = Int(upTimeoutSeconds * 2)
                for _ in 0..<ticks {
                    if once.isUsed { return }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if once.isUsed { return }
                    if let state = await backendState(of: node),
                       state == "NeedsLogin" || state == "NeedsMachineAuth" {
                        if once.claim() { continuation.resume(returning: .settled(state)) }
                        return
                    }
                }
            }
        }
    }

    /// 上游报的 BackendState → 我们这一侧的失败归因。
    ///
    /// 这是「谁该负责」的唯一判断点：未登录要一把新票、等批准要等人、其余才轮到网络。
    /// `ticket` 只用来分辨「未登录」的两种来源：刚贴的被拒（换一把），
    /// 还是本机根本没身份（造一把）。
    private static func failure(forBackendState state: String,
                               ticket: String?) -> UpOutcome {
        switch state {
        case "NeedsLogin":
            return ticket == nil ? .fatal(.needsAuthKey) : .fatal(.badKey)
        case "NeedsMachineAuth":
            return .fatal(.pendingApproval)
        default:
            // Starting / Stopped / NoState：都还没到有结论的地步，值得再试。
            return .retryable(.unreachable)
        }
    }

    /// 失败归因：消息里认得出「key 被拒」= 不可重试；其余（连不上、证书没信任）算可重试。
    ///
    /// 三种写法都抄自上游真话：`tsnet.Up: backend: invalid key: API key … not valid`
    /// （Tailscale 控制面拒 key，真机日志原文）、`invalid authkey`（headscale 一类）、
    /// `auth key … not valid`。
    ///
    /// 不把匹配放宽到 `not valid`：证书链不对也带这两个词，而那一类确实该算不可达。
    private static func outcome(forMessage message: String) -> UpOutcome {
        let lower = message.lowercased()
        let keyRejected = ["authkey", "auth key", "invalid key"].contains { lower.contains($0) }
        return keyRejected ? .fatal(.badKey) : .retryable(.unreachable)
    }

    /// 落失败并清掉只有成功才该留的东西。**只在终局调用** —— 重试期间保持原状态。
    private func finishFailed(_ failure: TailnetNodeFailure) {
        gatewaySession = nil
        stopPathPolling()
        transition(.registrationFailed(failure))
    }

    private func transition(_ event: TailnetNodeState.Event) {
        let old = state
        state = TailnetNodeState.handle(event, from: state)
        Log.info(Log.Module.mesh, "state changed", [
            "from": String(describing: old),
            "event": String(describing: event),
            "to": String(describing: state),
        ])
        onNodeChanged?()
    }

    // MARK: - tsnet 状态目录（损坏 → noKey，fail-closed）

    /// App 沙盒内的节点状态目录。卸载 App 随之蒸发 → 重开落 noKey。
    private static var stateDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tsnet", isDirectory: true)
    }

    /// 目录存在但读不了 = 半途被杀写坏 = 视为未注册（fail-closed）；不存在 = 干净首启。
    private static func stateStoreHealthy() -> Bool {
        stateStoreHealthy(in: stateDir)
    }

    /// 判定的本体 —— 入参就是全部输入，判据直接打这里，不碰 App 沙盒。
    ///
    /// 三条分支各有后果：**不存在** = 干净首启（有 key 就走 `registering`）；**存在但读不了**
    /// 或**不是目录** = 半途被杀写坏，视为未注册（fail-closed，宁可重新注册也不拿半份身份起）；
    /// **可读** = 重开不重注册。
    static func stateStoreHealthy(in dir: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue && FileManager.default.isReadableFile(atPath: dir.path)
    }

    /// 丢掉节点持久状态（整个目录）。**只有一条路会走到这里：换了控制面。**
    ///
    /// 那包文件是 tsnet 的 node state，含登录身份与 node key —— 全部属于上一家控制面。
    /// 不删的后果不是报错，是「连上了但什么都通不了」，比删掉难查得多。
    /// 删完不补任何东西：下一次 `up` 会当成干净首启重建。
    private func discardNodeState(from reason: String) {
        let dir = Self.stateDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
            Log.info(Log.Module.mesh, "node state discarded, next up starts clean",
                     ["reason": reason])
        } catch {
            // 删不掉就照旧起：坏结果只是「可能连上但通不了」，而这是原本就有的行为。
            Log.warn(Log.Module.mesh,
                     "node state could not be discarded (\(reason)): \(String(describing: error))")
        }
    }
}

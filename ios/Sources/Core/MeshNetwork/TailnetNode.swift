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

    /// key 的可核对形式：头 11 位 + 尾 6 位，够对上 headscale 的 auth id，又不整串刷屏。
    private static func keyHint(_ key: String?) -> String {
        guard let key else { return "nil" }
        guard !key.isEmpty else { return "<empty>" }
        guard key.count > 20 else { return "<short:\(key.count)>" }
        return "\(key.prefix(11))…\(key.suffix(6))"
    }

    /// 状态机当前状态（界面据此渲染；迁移判定全在 `TailnetNodeState.handle`）。
    private(set) var state: TailnetNodeState = .noKey

    /// 起节点那段（`up()`）还在跑。**与 `state` 是两件事**：状态目录健康时 `launch` 一上来
    /// 就是 `.running`，而真正的接入还要跑最长约 49 秒。设置页与 `revive()` 都据此避让。
    private(set) var isStarting = false

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

    init(makeBackend: @escaping BackendFactory = TailnetBackends.live) {
        self.makeBackend = makeBackend
    }

    // MARK: - 接入 key（沙盒而非 Keychain：沙盒随卸载蒸发）

    enum TailnetKeyStore {
        private static let fileName = "tailnet-key"

        /// 空串不算 key：空串会被当「有 key」放行注册，注册请求自然不带票。
        static func load() -> String? {
            SecretFile.read(fileName).flatMap { $0.isEmpty ? nil : $0 }
        }

        static func save(_ key: String) {
            guard !key.isEmpty else { return }
            SecretFile.write(fileName, key)
        }
    }

    // MARK: - 入口（App 启动 / 设置页动作）

    /// App 启动：读 key 与节点持久状态 → 状态机判定 → 需要则起节点。
    func launch(config: MeshConfig) async {
        let key = TailnetKeyStore.load()
        let healthy = Self.stateStoreHealthy()
        Log.info(Log.Module.mesh, "launch: key=\(Self.keyHint(key)) stateDirHealthy=\(healthy) controlURL=\(config.controlURLString) gateway=\(config.gatewayURLString)")
        transition(.launch(keyPresent: key != nil, nodeStateHealthy: healthy))

        switch state {
        case .registering:
            await up(key: key, config: config)
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
            // 重开也照喂 key：状态目录健康 ≠ 注册完成，残缺状态不喂 key 会让 headscale 落
            // 交互注册。后端已 Running 时上游自行忽略 key。
            await up(key: key, config: config)
        default:
            break
        }
    }

    /// 设置页提交接入 key：进沙盒存储 → registering → 注册。
    /// 正在起节点时拒绝：两条并发时，任一条的终局都会清掉另一条的产物。
    func submitKey(_ key: String, config: MeshConfig) async -> MeshActionAcceptance {
        guard !isStarting else {
            Log.info(Log.Module.mesh, "submitKey: refused — node is starting")
            return .refusedWhileNodeStarting
        }
        Log.info(Log.Module.mesh, "submitKey: \(Self.keyHint(key)) (\(key.count) chars)")
        guard !key.isEmpty else {
            // 空提交不进状态机注册流程 —— 动作照样算「接下」，成不成由状态机给。
            transition(.registrationFailed(.badKey))
            return .accepted
        }
        TailnetKeyStore.save(key)
        transition(.keySubmitted)
        await up(key: key, config: config)
        return .accepted
    }

    /// failed 修复后的重试（换 key / 网络恢复）。key 在不在由存储侧判定。
    func retry(config: MeshConfig) async -> MeshActionAcceptance {
        guard !isStarting else {
            Log.info(Log.Module.mesh, "retry: refused — node is starting")
            return .refusedWhileNodeStarting
        }
        let key = TailnetKeyStore.load()
        Log.info(Log.Module.mesh, "retry: key=\(Self.keyHint(key))")
        transition(.retry(keyPresent: key != nil))
        if case .registering = state {
            await up(key: key, config: config)
        }
        return .accepted
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

    /// 轮询等后端到 Running：注册落库有滞后，短窗口内多看几次；始终不到 = 没注册上。
    private static func backendRunning(_ node: any TailnetBackend) async -> Bool {
        for _ in 0..<3 {
            if await backendState(of: node) == "Running" { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
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
        case ready
        case retryable(TailnetNodeFailure)
        case fatal(TailnetNodeFailure)
    }

    /// 起 tsnet 节点并等登录完成；环境类失败自动重试。key 空表示本机没存过 key
    /// （上游对 Running 后端会自行忽略 key）。
    private func up(key: String?, config: MeshConfig) async {
        // **单飞**：同一时刻只允许一条起节点的路；`defer` 复位（`up` 有四条 return）。
        isStarting = true
        defer { isStarting = false }

        var attempt = 0
        while true {
            attempt += 1
            switch await attemptUp(key: key, config: config) {
            case .ready:
                transition(.registrationSucceeded)
                startPathPolling()
                // 根部激活回调：同值迁移不触发 onChange，激活只能挂在「session 刚建成」这个时点。
                if let session = gatewaySession { onVerifiedRunning?(session) }
                return

            case .fatal(let failure):
                Log.info(Log.Module.mesh, "up: not retrying (\(failure)) — retrying cannot change it")
                finishFailed(failure)
                return

            case .retryable(let failure):
                guard attempt < Self.upAttemptLimit else {
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
    private func attemptUp(key: String?, config: MeshConfig) async -> UpOutcome {
        guard config.isComplete, let controlURL = config.controlURL else {
            // 配置没填全：视同不可达（界面提示去设置页补地址）。重试不会补上地址。
            Log.info(Log.Module.mesh, "up: config incomplete → unreachable")
            return .fatal(.unreachable)
        }
        Log.info(Log.Module.mesh,
                 "up: start hostname=dsh-iphone controlURL=\(controlURL.absoluteString)"
                 + " key=\(Self.keyHint(key))")

        let node: any TailnetBackend
        do {
            node = try makeBackend(
                TailnetBackendSpec(
                    hostName: "dsh-iphone",
                    stateDir: Self.stateDir.path,
                    authKey: key,
                    controlURL: controlURL.absoluteString
                )
            )
        } catch {
            let message = String(describing: error)
            Log.info(Log.Module.mesh, "up: init threw \(message)")
            return Self.outcome(forMessage: message)
        }
        self.node = node

        switch await Self.runUp(node) {
        case .timedOut:
            Log.info(Log.Module.mesh,
                     "up: no answer in \(Int(Self.upTimeoutSeconds))s"
                     + " — closing this node (upstream has no timeout of its own)")
            // `close` 是上游指定的取消手段：它让卡住的 `up()` 收尾，不留一条还在跑的 Go 侧节点。
            try? await node.close()
            self.node = nil
            return .retryable(.unreachable)

        case .failed(let message):
            Log.info(Log.Module.mesh, "up: threw \(message)")
            self.node = nil
            return Self.outcome(forMessage: message)

        case .returned:
            // 闭合信号：up() 返回 ≠ 注册完成（停在 NeedsLogin 时它也返回），
            // BackendState == Running 才算。
            let backendNow = await Self.backendState(of: node) ?? "<unreadable>"
            Log.info(Log.Module.mesh,
                     "up: returned, BackendState=\(backendNow) (waiting up to 3s for Running)")
            if await Self.backendRunning(node) {
                Log.info(Log.Module.mesh, "up: verified Running")
                do {
                    gatewaySession = try await node.makeGatewaySession()
                } catch {
                    Log.info(Log.Module.mesh,
                             "up: session build threw \(String(describing: error))")
                    self.node = nil
                    return .retryable(.unreachable)
                }
                return .ready
            }
            // 有 key 却停在 NeedsLogin = key 被拒；没有 key = 环境问题（可以补 key 后再试）。
            Log.info(Log.Module.mesh,
                     "up: NOT Running after 3s (key=\(key == nil ? "absent" : "present"))")
            return key == nil ? .retryable(.unreachable) : .fatal(.badKey)
        }
    }

    /// 跑一次 `up()`，到点就放弃；超时那一支由调用方 `close` 收尾（取消 Task 中断不了 Go 侧等待）。
    private enum UpStep: Sendable {
        case returned
        case failed(String)
        case timedOut
    }

    private static func runUp(_ node: any TailnetBackend) async -> UpStep {
        await withTaskGroup(of: UpStep.self) { group in
            group.addTask {
                do {
                    try await node.up()
                    return .returned
                } catch {
                    return .failed(String(describing: error))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(upTimeoutSeconds * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// 失败归因：消息含 authkey 字样 = key 被拒；其余（连不上、证书没信任）一律 unreachable。
    private static func outcome(forMessage message: String) -> UpOutcome {
        let lower = message.lowercased()
        let keyRejected = lower.contains("authkey") || lower.contains("auth key")
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
        Log.info(Log.Module.mesh, "state: \(old) --\(event)--> \(state)")
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
        let dir = stateDir
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) else {
            return false   // 首启：走 registering（有 key 时）
        }
        return isDirectory.boolValue && FileManager.default.isReadableFile(atPath: dir.path)
    }
}

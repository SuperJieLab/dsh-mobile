/**
 * TailscaleKit 的包装层：节点生命周期 → `TailnetNodeState` 事件。
 *
 * 只做「上游调用 + 结果归类成状态机事件」，迁移决策全部在纯状态机 `TailnetNodeState`。
 * 注册成功的副产物是一只走 SOCKS5 回环的 `gatewaySession`，`GatewayClient` 注入它之后
 * 流量全部进 tailnet。
 *
 * 上游形状（libtailscale，`TailscaleNode.swift` 实读）：
 * - `init(config:)` 即 `tailscale_start`；`up()` 阻塞到登录完成，key 错误从这里冒出；
 * - 状态目录（`Configuration.path`）持久节点身份 —— 重开 App 不重注册；
 * - `TailscaleError` 没有结构化的 key 错误分支，badKey / unreachable 只能按错误消息归类
 *   —— 这里是薄翻译层。
 */import Foundation
import TailscaleKit

@MainActor
final class TailnetNode: ObservableObject {

    /// key 的可核对形式：头 11 位（`hskey-auth-`）+ 尾 6 位 —— 足以和 headscale
    /// 日志里的 auth id / VPS preauthkeys list 对号，又不整串刷屏。
    private static func keyHint(_ key: String?) -> String {
        guard let key else { return "nil" }
        guard !key.isEmpty else { return "<empty>" }
        guard key.count > 20 else { return "<short:\(key.count)>" }
        return "\(key.prefix(11))…\(key.suffix(6))"
    }

    /// 状态机当前状态（界面据此渲染；迁移判定全在 `TailnetNodeState.handle`）。
    @Published private(set) var state: TailnetNodeState = .noKey

    /// Running 后可用：全部流量进 tailnet 的 session，给 `GatewayClient` 注入。
    private(set) var gatewaySession: URLSession?

    /// 当前到网关对端的路径：Running 期间轮询刷新，其余状态为 nil。
    /// 展示层的唯一数据源 —— `ConnectionBadge` 只吃这个值，不感知本类型。
    @Published private(set) var meshPath: CarrierPath?

    /// 节点验证 Running、tailnet session 建成的那一刻（App 据此把传输切进虚拟网）。
    /// 同值迁移不触发 SwiftUI onChange，激活只能挂回调。
    var onVerifiedRunning: ((URLSession) -> Void)?

    /// 对外可见事实变化的推送通道（连接域唯一消费者）：状态迁移与路径刷新处调用。
    /// 通知本身零成本，重复通知由接收方的投影吸收。
    var onNodeChanged: (() -> Void)?

    private var node: TailscaleNode?
    private var pathPollTask: Task<Void, Never>?

    // MARK: - 接入 key（App 沙盒而非 Keychain：Keychain 跨卸载存活且无法随卸载清除，
    // 与「卸载即失效」冲突；沙盒随卸载蒸发）

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
        Log.info(Log.Module.mesh, "launch: key=\(Self.keyHint(key)) stateDirHealthy=\(healthy) controlURL=\(config.controlURLString ?? "nil") gateway=\(config.gatewayURLString ?? "nil")")
        transition(.launch(keyPresent: key != nil, nodeStateHealthy: healthy))

        switch state {
        case .registering:
            await up(key: key, config: config, onAuthkeyError: { .registrationFailed($0) })
        case .running:
            // 幂等：同一进程内二次 launch 会把旧 socket 全杀掉 —— socks5 / localapi
            // 随即报 use of closed network connection，徽章上的路径标签也一起掉。
            // 所以节点已验证 Running 且组网 session 还活着时不再 re-up，只把激活
            // 回调补到位。冷启动（新进程、gatewaySession 必为 nil）不受影响。
            if let session = gatewaySession {
                Log.info(Log.Module.mesh, "launch: node already running with live session — skip re-up")
                onVerifiedRunning?(session)
                startPathPolling()
                return
            }
            // 重开也照喂 key（在才喂）：状态目录健康 ≠ 注册完成——上次起节点可能只写
            // 了目录就退出，残缺状态 + 不喂 key ⇒ 注册请求不带 key，headscale 落
            // 交互注册回 AuthURL，永远不上节点表。后端已 Running 时
            // 上游自行忽略 key（tsnet.go「Ignoring authkey」分支），无副作用。
            await up(key: key, config: config, onAuthkeyError: { .registrationFailed($0) })
        default:
            break
        }
    }

    /// 设置页提交接入 key：进沙盒存储 → registering → 注册。
    func submitKey(_ key: String, config: MeshConfig) async {
        Log.info(Log.Module.mesh, "submitKey: \(Self.keyHint(key)) (\(key.count) chars)")
        guard !key.isEmpty else {
            // 空提交不进状态机注册流程。
            transition(.registrationFailed(.badKey))
            return
        }
        TailnetKeyStore.save(key)
        transition(.keySubmitted)
        await up(key: key, config: config, onAuthkeyError: { .registrationFailed($0) })
    }

    /// failed 修复后的重试（换 key / 网络恢复）。key 在不在由存储侧判定。
    func retry(config: MeshConfig) async {
        let key = TailnetKeyStore.load()
        Log.info(Log.Module.mesh, "retry: key=\(Self.keyHint(key))")
        transition(.retry(keyPresent: key != nil))
        if case .registering = state {
            await up(key: key, config: config, onAuthkeyError: { .registrationFailed($0) })
        }
    }

    /// 回前台的探活（节点复活场景的节点层侧）：tsnet 的复活是上游行为（状态在
    /// 进程内，前台即恢复），这里只探测状态是否仍可读。读不了 = 节点已死 → 如实落
    /// Failed(unreachable)，不自动重试（异常点表：不做重试风暴，重试入口在设置页）。
    func revive() async {
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
    private static func backendState(of node: TailscaleNode?) async -> String? {
        guard let node,
              let data = try? await node.statusJSON(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["BackendState"] as? String
    }

    /// 轮询等后端到 Running：注册落库有滞后，短窗口内多看几次；始终不到 = 没注册上。
    private static func backendRunning(_ node: TailscaleNode) async -> Bool {
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

    /// 起 tsnet 节点并等登录完成。key 空表示本机没存过 key（上游对 Running 后端会自行忽略 key）。
    private func up(key: String?, config: MeshConfig, onAuthkeyError: ((TailnetNodeFailure) -> TailnetNodeState.Event)? = nil) async {
        guard config.isComplete, let controlURL = config.controlURL else {
            // 配置没填全：视同不可达（界面提示去设置页补地址）。
            Log.info(Log.Module.mesh, "up: config incomplete → registrationFailed(unreachable)")
            transition(.registrationFailed(.unreachable))
            return
        }
        do {
            Log.info(Log.Module.mesh, "up: start hostname=dsh-iphone controlURL=\(controlURL.absoluteString) key=\(Self.keyHint(key))")
            let node = try TailscaleNode(
                config: Configuration(
                    hostName: "dsh-iphone",
                    path: Self.stateDir.path,
                    authKey: key,
                    controlURL: controlURL.absoluteString
                ),
                logger: nil
            )
            self.node = node
            try await node.up()
            // 闭合信号：up() 返回 ≠ 注册完成 —— 后端停在
            // NeedsLogin、控制面回 AuthURL 时 up() 也返回。只有 statusJSON 报
            // BackendState == Running 才认成功；否则按 key 有无归因（有 key 还
            // 停在 NeedsLogin = key 被拒）。
            let backendNow = await Self.backendState(of: node) ?? "<unreadable>"
            Log.info(Log.Module.mesh, "up: returned, BackendState=\(backendNow) (waiting up to 3s for Running)")
            if await Self.backendRunning(node) {
                Log.info(Log.Module.mesh, "up: verified Running → registrationSucceeded")
                gatewaySession = try await TailnetURLSession.makeSession(for: node)
                transition(.registrationSucceeded)
                startPathPolling()
                // 根部激活回调：App 的 onChange(of: state) 在同值迁移
                // （running→running）时不触发，隧道组网的激活只能挂在「session 刚建成」
                // 这个确定性时点上，不能靠状态 diff。
                onVerifiedRunning?(gatewaySession!)
            } else {
                Log.info(Log.Module.mesh, "up: NOT Running after 3s → registrationFailed(key=\(key == nil ? "absent→unreachable" : "present→badKey"))")
                transition(.registrationFailed(key == nil ? .unreachable : .badKey))
            }
        } catch {
            self.node = nil
            gatewaySession = nil
            stopPathPolling()
            Log.info(Log.Module.mesh, "up: threw \(String(describing: error))")
            transition(Self.classify(error, onto: onAuthkeyError))
        }
    }

    /// 上游错误 → 状态机事件。key 相关的判据 = 错误消息含 authkey 字样；
    /// 其余（连不上控制面、证书没信任）一律 unreachable —— 文案引导查描述文件。
    private static func classify(_ error: Error, onto event: ((TailnetNodeFailure) -> TailnetNodeState.Event)?) -> TailnetNodeState.Event {
        let message = String(describing: error).lowercased()
        let reason: TailnetNodeFailure = message.contains("authkey") || message.contains("auth key")
            ? .badKey
            : .unreachable
        return event?(reason) ?? .nodeUnreachable
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

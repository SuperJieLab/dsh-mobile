import Foundation

/**
 * 订阅流的连接编排 —— `URLSessionWebSocketTask` 上的四件事：
 *
 * 1. **代次**：本地单调计数；每次（重）连接都是新代次，旧代次回调一律丢弃 ——
 *    迟到的旧帧不能污染新代次视图。
 * 2. **退避重连**：base 500ms × 2^n、抖动 50–100%、封顶 10s，就绪硬超时 45s（取值来由见
 *    `readyTimeout`）；**重连即重新 open**，新 opening 重建窗口、不做水位续传。
 * 3. **心跳**：2s ping 一次，但**只在没有流在等打开帧时判死** —— 正在等打开帧的那一段归
 *    就绪硬超时管，理由见 `livenessTick`；URLSession 自动回服务端的 ping，这里只管
 *    「对面还活着吗」。
 * 4. **流编号**：每次开流现造一个、永不复用（`newStreamId`）。编号是「这条连接上这条流」
 *    的身份，只有这一层知道哪些号在用 —— 于是它也是唯一的造号点。
 *
 * **「要连着」与「要开哪条流」是两件事**：`activate()` 只表示要一条连接（App 在前台），
 * 登记一份订阅才表示要看某个会话。离开会话只取消那条流，连接留着。
 *
 * **一条连接上挂着若干条流。** `streams` 按订阅者身份索引，表项装订阅、编号、要发出去的
 * 文本，以及这条流自己的退避档位。两条流平级：谁都不占谁的位，一条坏了不动另一条。
 *
 * 本类只回答「线还在不在」：它解帧的外壳（三个字段存在与否），按编号归属后把整帧原样交给
 * 订阅方，再按对方回的 `StreamReply` 决定动作。它不认识 op 名、不认识帧类型的取值 ——
 * 要发的开流内容由订阅方凭刚造好的编号拼出来（`Subscription.build`）。
 *
 * **订阅方的答复只作用于它那一条流**（`reopen` / `retry` / `stop`）。连接级重连只有三个
 * 触发者 —— socket 关闭、心跳判死、帧层破坏，全在本类自己的代码里。
 *
 * 协议名与端口全从 `GatewayClient.baseURL` 推导 —— 全 App 只有一个要改的地址。
 */
@MainActor
final class FollowClient: NSObject {

    /// 连接阶段。`waiting` 携带下一次重连前的毫秒数，界面可以如实显示。
    enum Phase: Equatable {
        case idle
        case connecting
        case ready
        case waiting(ms: Int)
    }

    /// 一份订阅：谁在看、日志里叫什么、开流文本怎么拼、帧怎么判。
    ///
    /// 四样**一起**交进来（而不是先登记、再设一个 `onFrame`）：两个入口会让「谁的回调」
    /// 在注销之后仍然挂着 —— 那时新订阅者已经就位，旧回调却还在收帧。
    struct Subscription {
        /// 订阅者身份。注销时比对：不是当前订阅者就什么都不做。
        ///
        /// SwiftUI 不保证 `onDisappear` 与下一个页面的 `task` 谁先跑；不带身份时，
        /// 「上一屏的收尾」会把「这一屏刚开好的流」关掉。
        let owner: AnyObject
        /// 日志里用来区分实例的标识（会话 id）。本类不解释它。
        let label: String
        /// 凭刚造好的编号拼出开流文本 —— 连接层不认识 `op` 与会话，拼装归订阅方。
        let build: (StreamId) throws -> String
        /// 收到一帧：外壳 + 原始字节。返回值决定这条流下一步怎么办。
        let handler: (MuxServerEnvelope, Data) -> StreamReply

        init(
            owner: AnyObject,
            label: String,
            build: @escaping (StreamId) throws -> String,
            handler: @escaping (MuxServerEnvelope, Data) -> StreamReply
        ) {
            self.owner = owner
            self.label = label
            self.build = build
            self.handler = handler
        }
    }

    /// 一条已登记的流。
    ///
    /// 做成 class 而不是字典里的 struct：编号、文本、退避档位、在途定时器都要被几处就地改动
    /// （重开换号、建立后清档位、注销时取消定时器），值语义会让每一处都变成一次回写。
    private final class OpenStream {
        let subscription: Subscription
        /// 登记顺序。只用于「谁先开的」这类诊断与稳定排序 —— 帧的归属按编号，
        /// 无编号帧按收货人，都不看它。
        let sequence: Int
        var id: StreamId
        var text: String
        /// 这条流自己的退避档位。按流一份，一条流的退避不拖累另一条。
        var retryAttempt = 0
        var retryWorkItem: DispatchWorkItem?
        /// 「已发出 open、还没收到开口帧」的那一段。心跳让路的唯一判据（见 `livenessTick`）。
        var openInFlight = false
        /// 这一条流是否已经开出去过。再开一次就是**新的开流**，要新号（`sendAllOpens`）。
        var openedAtLeastOnce = false

        init(subscription: Subscription, sequence: Int, id: StreamId, text: String) {
            self.subscription = subscription
            self.sequence = sequence
            self.id = id
            self.text = text
        }
    }

    // MARK: - 回调（由宿主注入；全部在主线程）

    /// 连接阶段变化（连接态指示器的数据源）。
    var onPhaseChange: ((Phase) -> Void)?
    /// 没有流编号的帧的收货人。这类帧不属于任何一条流，属于这条连接。
    ///
    /// 一个成员而不是一条「谁代收」的规则：帧没有编号时，「归谁」不该取决于谁先登记 ——
    /// 那条规则既没有判据，也随屏幕开关漂。收货人与连接同寿，由根部接上。
    var unscopedSink: (any UnscopedFrameSink)?
    /// 取一张有效的访问凭证 —— upgrade 请求带上它。**没有就说明现在不该连**：
    /// 见 `connect` 里对空票的处理。
    var authorizationProvider: (() -> String?)?
    /// 换一张票。`connect` 见空票时调它，**并且由本类自己决定下一步**（见 `renewThenRetry`）：
    /// 换到了就跳过剩余退避重连，换不到就按处境等或停。
    ///
    /// 为什么决定权在这里而不是注入方：退避重连这条路上没有别的东西会去换票（`activate` 与
    /// `reconnectNow` 的前置都只在各自入口跑一次）。票过期后若照旧裸连，每一轮退避都是一次
    /// 注定被拒的握手，而且**永不收敛** —— 服务端看不到票，我们也永远拿不到新的，直到有人回
    /// 前台或重新进屏。那表现就是静默断流，不是慢一下。
    var ticketRenewer: (() async -> AccessTicket)?
    /// 建连的传输与地址每次现取：store 激活后下一轮连接即走隧道，本类零改动。
    /// 返回 nil = 端点不存在（未激活）——不猜地址，connect 据此进退避等待。
    var sessionProvider: () -> URLSession = { .shared }
    var baseURLProvider: () -> URL? = { nil }

    // MARK: - 状态

    /// 连接阶段 —— 对外由 `onPhaseChange` 转发，视图读宿主的 `phase`。
    /// 通知挂在 setter 上：`connect`、收到打开帧、退避等待、`deactivate` 四处都会改它，
    /// 手写必定漏接一处。**开流不改它** —— 在已就绪的连接上开第二条流，屏幕不该闪「连接中」。
    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }

    /// 连接代次 —— 每次连接递增；回调带着发起时的代次，对不上就丢。
    private var generation = 0
    /// 这条连接上登记着的流，键是订阅者身份。空 = 一条流都没有；**连接照样活着**。
    private var streams: [ObjectIdentifier: OpenStream] = [:]
    /// 登记过多少条（只增）—— `OpenStream.sequence` 的来源。
    private var registrations = 0
    /// 已建成的流编号。`phase` 说连接，这个集合说每条流。
    ///
    /// 对测试可读：本层「建成」的消费点（`noteReply`）不碰 socket，值得被单独断言 ——
    /// 这段迁移错了不会编译失败，症状是心跳永不激活或退避永不归零。
    private(set) var established: Set<StreamId> = []
    private var task: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    /// 本代连接连续未回的 pong 数 —— 随代次清零，见 `connect`。**唯一写者是心跳那一拍**
    ///（`livenessTick` 算出来的结果），别处不直接改它。
    private var missedPongs = 0
    /// 本拍内是否收到过对端的东西（一帧，或我们 ping 的 pong）。
    /// 心跳每拍**消费一次**（读过即清零），
    /// 理由见 `livenessTick`。
    ///
    /// 对测试可读：`handleMessage` 的**顺序**（先记证据、再归流）是判据，而那是「切会话时
    /// 残帧不能让连接被自己判死」的唯一实现处。
    private(set) var heardFromPeer = false
    /// 重连定时器 —— teardown 时要能取消；同一时刻至多一个，见 `scheduleReconnect`。
    private var reconnectWorkItem: DispatchWorkItem?

    /// 就绪硬超时 —— 从**每一次开流尝试**（首连与重开，见 `armReadyTimeout`）算起，多久没等到
    /// 打开帧就当这次尝试没成。
    ///
    /// 取值 45s **不是**照抄上游的 15s（那是给快链路的）。我们的打开帧是这条流里**最大的
    /// 一帧**，而链路的吞吐可以低到 ~125 KB/s（0.51 MiB 的打开帧要传约 4.2 秒）。
    /// 网关承诺的打开帧上界是 4 MiB（`DEFAULT_LIMITS.maxOpeningBytes`），于是在最慢链路上
    /// 4 MiB ÷ 125 KB/s ≈ 34 秒，再加建连（约 2 秒）⇒ 45 秒。
    ///
    /// **这个数由「上界的尺寸」与「实测最慢吞吐」共同决定，不是拍的** —— 两端任一侧改了
    /// 上界，这个数都要跟着重算。它管的是「没建起来」，与心跳（管「建起来之后死了」）不重叠。
    static let readyTimeout: TimeInterval = 45
    private let pingInterval: TimeInterval = 2
    private let maxMissedPongs = 2

    private static let streamPath = "/rpc/stream"
    private static let baseBackoffMs = 500
    private static let maxBackoffMs = 10_000

    /// 单帧接收上限 —— 网关承诺打开帧不超过 4 MiB（网关侧
    /// `DEFAULT_LIMITS.maxOpeningBytes`），这里取它的两倍：覆盖任何非窗口帧，并留出
    /// 两端读数差异的余量。**这个属性默认只有 1 MiB**，那正是「某个会话打不开」的
    /// 成因；它必须显著大于网关的上界，否则同一个断连只是换个地方发生。
    ///
    /// 不设为 `private`：它是两端配套契约的一半，测试要能断言它。
    static let maximumMessageSize = 8 * 1024 * 1024

    /// 已交给 socket 的帧文本（只有开流与取消两种，都是「事务」，量小且可数）。
    ///
    /// 对测试可读，理由只有一个：判据要问「注销时到底发没发帧、发的是哪个编号」——
    /// 那件事在一条真 socket 上不可观测，而它正是本类最容易做错的一半。
    private(set) var sentFrames: [String] = []

    /// 是否要有一条连接 —— **只有它决定连不连**，与「要开哪条流」无关。
    ///
    /// 前台常驻的字面含义：停在会话列表时它仍为真，于是连接与心跳照旧。
    private var active = false

    // MARK: - 生命周期

    /// 要一条连接（App 到了前台）。此时可以一条流都没有。
    func activate() {
        guard !active else { return }
        active = true
        connect()
    }

    /// 不要连接了（App 收尾 / 测试清理）：关连接、取消一切定时器。
    func deactivate() {
        active = false
        forgetAll()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeTask()
        generation += 1 // 旧代次的一切回调就此作废
        phase = .idle
    }

    /// 登记一条流：造一个新编号、拼出开流文本；连接在就立刻发，不在就起一次连接。
    ///
    /// 同一个订阅者重复登记是幂等的（视图重算不该换号）。**不同的订阅者各自一条流** ——
    /// 后登记者不会顶掉先登记者，否则「会话详情开着时事件流建不起来」与「事件流占着连接时
    /// 会话详情打不开」就是同一个故障的两种表现。
    func open(_ subscription: Subscription) {
        let key = ObjectIdentifier(subscription.owner)
        guard streams[key] == nil else { return }
        guard let fresh = mint(subscription) else { return }
        registrations += 1
        let stream = OpenStream(
            subscription: subscription, sequence: registrations, id: fresh.id, text: fresh.text
        )
        streams[key] = stream
        guard active else { return }
        if task != nil {
            // 连接已经在（或在握手）：只发开流帧，**不重建连接** —— 这正是常驻连接的收益。
            sendOpen(stream)
        } else {
            // 退避里排着的那一拍取代掉：流已经登记好了，没有理由再等一轮。
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            connect()
        }
    }

    /// 注销一份订阅：只注销「自己登记的那一条」，晚到的注销不碰别的流。
    func close(owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        guard let stream = streams[key] else { return }
        // 没发过的流没有可取消的东西：`send` 在无连接时一个字节都不记。
        sendCancel(stream.id)
        forget(key)
    }

    /// 这一条流换号重开：基线丢了、或用户按了「重试」。**连接与别的流不动。**
    ///
    /// **先取消旧号，再换号重开**：同号重开时，网关的流表里可能还占着那个编号，而「占用中」
    /// 的打开会被直接忽略 —— 这次重开就什么都不会发生，只能等 45 秒的就绪超时兜底。
    ///
    /// 连接不在时（退避里、或从没建起来）顺手起一次连接：调用方说的是「现在就要这条流」，
    /// 而排在后面的那一拍退避挡着的正是这件事。
    func reopen(owner: AnyObject) {
        guard active else { return }
        reopen(key: ObjectIdentifier(owner))
    }

    /// 某个订阅者此刻的流编号。对测试可读：编号是「按号归流」的比对基准，
    /// 而流表本身不该为了断言而敞开口子。
    func streamId(of owner: AnyObject) -> StreamId? {
        streams[ObjectIdentifier(owner)]?.id
    }

    /// 回前台立即触发一次重连 —— 上游「恢复立即试」（online 事件 → 重连控制器）的复现。
    /// 退避窗口里的等待被跳过；已在握手或就绪的连接不受影响，不叠加并发连接。
    func reconnectNow() {
        guard active else { return }
        guard phase != .ready, phase != .connecting else { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        Log.info(Log.Module.session, "foreground — reconnecting immediately (skipping backoff)")
        connect()
    }

    // MARK: - 连接

    /// 起一次连接（新代次）。
    ///
    /// 对内可见（不 `private`）与 `handleMessage` / `route` / `noteReply` 同理：这里有一条
    /// 只有在此处才断言得到的**契约** —— 换代次之后每条登记着的流都要用自己的新编号重开。
    /// 走一条真 socket 也能看见它，但那时「谁该重开」与网络的偶然混在一起。
    func connect() {
        guard active else { return }
        // 无端点（组网未激活）：不猜地址，也不动代次与 phase 的连接语义，
        // 直接进既有退避循环 —— 激活后下一轮自动连上。
        guard let endpoint = baseURLProvider() else {
            scheduleReconnect()
            return
        }
        // 注意：不在这里清零 reconnectAttempt —— 退避档位必须随失败次数爬升，
        // 否则握手持续失败时会退化成每秒一次的疯狂循环。
        generation += 1
        let current = generation
        // 新代次的第一帧到达之前通知：消费方要在这之前把上一代的基线清掉，
        // 否则重投进来的项会与旧项混在一起。

        // 心跳的判据随代次清零：连失数与「活过」的证据都不继承。上一代的欠账算到这一代
        // 头上会自锁 —— 一次没建成的连接把连失数攒到上限之后，此后每一代都在第一个心跳
        // 节拍就被判死，2 秒一转、永不恢复。
        missedPongs = 0
        heardFromPeer = false
        // 这一代还没开流，建成状态不继承：上一代的「建成」属于上一代的连接。
        established = []
        phase = .connecting
        // 连接发起时刻：与打开帧记录配对后可以算追平延迟（按代次对齐）。归属走普通字段
        // 而不是 perf 记录里的会话位 —— 本层不知道「会话」是什么，它只有一个不透明标签。
        Log.perf(Log.Module.session, PerfRecord(
            seg: .dev, t: PerfRecord.nowMs(),
            fields: ["kind": .text("connect-init"), "gen": .number(Double(current)),
                     "who": .text(labelsText)]
        ))

        // 上一代次的连接必须先关掉：不关的话旧 socket 的 receive/heartbeat
        // 还在（回调虽被代次拦住，连接本身泄漏），且系统的连接行为会互相干扰。
        if task !== nil {
            Log.debug(Log.Module.session, "g\(current) closing previous task before connecting")
            closeTask()
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            phase = .idle
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = Self.streamPath

        // 没有票**不裸连**：这一发必定被 401 拒。交给 `renewThenRetry` 决定下一步。
        guard let access = authorizationProvider?() else {
            Log.info(Log.Module.session, "connect g\(current) skipped — no access ticket")
            renewThenRetry()
            return
        }

        // upgrade 请求带身份：与 HTTP 同一个头、同一张票。
        var upgradeRequest = URLRequest(url: components.url!)
        upgradeRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let webSocketTask = sessionProvider().webSocketTask(with: upgradeRequest)
        // 必须在 resume 之前设：超过上限的帧会让 receive 直接以 POSIX 40 失败，
        // 而系统默认只给 1 MiB —— 一个 1.25 MB 的打开帧就足以把会话永远关在门外。
        webSocketTask.maximumMessageSize = Self.maximumMessageSize
        task = webSocketTask
        // 带上标识：`g2` 在两个实例（进出会话详情各一份订阅）里会重号，
        // 只有它加上会话能区分「谁的第 2 代」。
        Log.info(Log.Module.session, "connect g\(current) [\(labelsText)] → \(components.url!)")
        webSocketTask.resume()

        // 握手由系统完成，开流内容立即发出（未就绪的连接会替我们排队）——
        // 服务端等的就是它：没有它，永远不会有打开帧。没有流时这几句什么都不发。
        sendAllOpens()

        // 就绪硬超时不在这里起 —— 它挂在 `sendOpen` 上，于是「每一次开流尝试」都带时限
        //（首连与重开同路），见 `armReadyTimeout`。
        receiveLoop(on: webSocketTask, generation: current)
        heartbeat(on: webSocketTask, generation: current)
    }

    /// 这条连接上登记着的流标签（按登记序、逗号分隔），只进日志 —— 本层不解释它们。
    private var labelsText: String {
        let labels = orderedStreams.map(\.subscription.label)
        return labels.isEmpty ? "-" : labels.joined(separator: ",")
    }

    /// 按登记顺序排好的流。开流、日志、无编号帧的归属都跟着这个次序 ——
    /// 乱序会让「先登记者」变成一次偶然。
    private var orderedStreams: [OpenStream] {
        streams.values.sorted { $0.sequence < $1.sequence }
    }

    /// 在当前连接上把每一条登记好的流都开出去（首连与重连同路）。
    ///
    /// 换代次之后每条流都用**新号**：上一代那个号连同它还在路上的残帧一起作废，
    /// 而新号是「这一次开流」的身份。第一次开出去的流不算重新开，它的号是登记时造的那个。
    private func sendAllOpens() {
        for stream in orderedStreams {
            if stream.openedAtLeastOnce {
                guard renumber(stream) else { continue }
            }
            sendOpen(stream)
        }
    }

    /// 在这一条流上发出它的开流内容，开始（或重建）它。
    ///
    /// **不动连接阶段**：在已经就绪的连接上开第二条流，屏幕不该闪一下「连接中」——
    /// 阶段的含义是「这条连接走到哪一步了」，与登记了几条流无关。
    private func sendOpen(_ stream: OpenStream) {
        // 这一次尝试还没建成：旧编号的「建成」不成立，否则就绪超时与心跳都会照着旧账判。
        established.remove(stream.id)
        stream.openInFlight = true
        stream.openedAtLeastOnce = true
        send(text: stream.text)
        // 每一次开流尝试都在这里带时限 —— 首连与重开（收尾帧、`reopen`）走的是同一个入口。
        // 只在 `connect` 里 arm 会漏掉重开：那时「等不到打开帧」就没有任何看门人
        //（心跳只管不在等打开帧的连接，见 `livenessTick`）。
        armReadyTimeout(stream: stream)
    }

    /// 发一条取消帧。**只对发过开流的那条流发** —— 没发过就没有可取消的东西。
    private func sendCancel(_ id: StreamId) {
        guard let text = try? MuxCancelFrame(streamId: id).encoded() else {
            Log.warn(Log.Module.session, "cancel frame encoding failed for stream \(id)")
            return
        }
        send(text: text)
    }

    /// 就绪硬超时：从**这次开流尝试**起算，多久没等到开口帧就当它没成。
    ///
    /// 按流各起一个 —— 每一条流都有自己的「这一次尝试」。超时的处置仍是连接级的
    /// （关连接、退避重连）：真要在流这一级处置，得先能让客户端区分「这条流没起来」与
    /// 「这条连接传不动」，而今天拿不到那个信号。
    ///
    /// ⚠️ `budget` 是**秒**，必须乘 10⁹ 转成纳秒。把秒数直接当纳秒传进去，超时会在
    /// 微秒级就到点 —— 每次连接都立即被判失败，开流帧被 cancel 成 -999，
    /// 于是永远收不到打开帧，而日志里只看到无穷无尽的「重连」。
    private func armReadyTimeout(stream: OpenStream) {
        guard let webSocketTask = task else { return }
        let current = generation
        let budget = Self.readyTimeout
        let labelForLog = stream.subscription.label
        let owner = ObjectIdentifier(stream.subscription.owner)
        let id = stream.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            // 判据是「还是这次尝试」：编号换了、条目没了、或已经建成，都说明这一拍作废。
            guard let self, self.generation == current, self.task === webSocketTask,
                  let live = self.streams[owner], live.id == id, live.openInFlight,
                  !self.established.contains(id) else { return }
            // 这一行是「这次连接为什么没成」的第一现场：45 秒还没等到打开帧，通常意味着
            // 慢链路正传一大帧（1.25 MB 在 125 KB/s 上要传约 10 秒），或者对面根本没在
            // 服务这个会话。
            Log.warn(Log.Module.session,
                     "g\(current) [\(labelForLog)] ready timeout (\(Int(budget))s) — closing and retrying")
            self.closeTask()
            self.scheduleReconnect()
        }
    }

    /// 关掉当前任务并使其回调作废（代次在外层管）。
    private func closeTask(from caller: String = #function) {
        if let task {
            Log.debug(Log.Module.session, "g\(generation) closeTask from \(caller)")
            task.cancel(with: .goingAway, reason: nil)
        }
        task = nil
    }

    // MARK: - 流

    /// 造一个新编号并让订阅方拼出文本 —— 造号与拼装是同一步的两半，分开写迟早漏掉一半。
    private func mint(_ subscription: Subscription) -> (id: StreamId, text: String)? {
        let id = Self.newStreamId()
        do {
            return (id, try subscription.build(id))
        } catch {
            // 编不出来意味着形状自己坏了：开一条注定看不懂的流只会让屏幕停在「正在同步…」。
            Log.error(Log.Module.session, "open frame encoding failed — not opening the stream")
            return nil
        }
    }

    /// 新编号 —— **全仓唯一的造号点**，且不复用。
    ///
    /// 小写形式：与上游 `randomUUID()` 的线上形态一致。不复用不是为了好看 —— 复用会让
    /// 旧流的收尾删到新流的登记，也会让旧流的残帧与新流同号。
    static func newStreamId() -> StreamId {
        UUID().uuidString.lowercased()
    }

    /// 换一个新编号并让订阅方重新拼文本。**旧号的取消由调用方决定时机** ——
    /// 「立刻重开」与「退避之后重开」在这件事上不同。
    @discardableResult
    private func renumber(_ stream: OpenStream) -> Bool {
        guard let fresh = mint(stream.subscription) else { return false }
        stream.id = fresh.id
        stream.text = fresh.text
        return true
    }

    /// 立刻换号重开一条流（不进退避）。
    private func reopen(key: ObjectIdentifier) {
        guard let stream = streams[key] else { return }
        stream.retryWorkItem?.cancel()
        stream.retryWorkItem = nil
        stream.retryAttempt = 0
        sendCancel(stream.id)
        established.remove(stream.id)
        stream.openInFlight = false
        guard renumber(stream) else { return }
        if task != nil {
            sendOpen(stream)
        } else {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            connect()
        }
    }

    /// 这条流被拒但值得再试：**按它自己的退避**换号重开。
    ///
    /// 旧号当场作废（被拒的流不会再有内容），新号等退避到了再造 —— 等待期间这条流不在等
    /// 开口帧，于是心跳照常判活，不会因为「一条流在睡觉」而放过半开连接。
    private func scheduleRetry(_ key: ObjectIdentifier) {
        guard active, let stream = streams[key] else { return }
        sendCancel(stream.id)
        established.remove(stream.id)
        stream.openInFlight = false
        // 新号当场就位，只是还没发出去 —— 于是这条流的编号始终是「下一个要用的」，
        // 不会是那个已经被拒掉的。等待期间若连接换届，`sendAllOpens` 会把它一起开出去。
        guard renumber(stream) else { return }

        stream.retryAttempt += 1
        let delay = Self.backoffDelayMs(attempt: stream.retryAttempt,
                                        random: Double.random(in: 0..<1))
        stream.retryWorkItem?.cancel()
        Log.info(Log.Module.session,
                 "stream [\(stream.subscription.label)] retry in \(delay)ms (attempt \(stream.retryAttempt))")
        let work = DispatchWorkItem { [weak self] in self?.retryNow(key) }
        stream.retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
    }

    /// 退避到点那一拍要不要真的发 open。
    ///
    /// 两个条件各挡一种重复：**在途**挡「同一个号被开两次」（网关把重复编号判成协议违规、
    /// 直接关连接），**已建成**挡「没必要的重开」。两种都不是「退避错了」，而是这一拍
    /// 已经被别的东西——重连、或用户手按的重试——提前满足了。
    ///
    /// 抽成纯函数是为了让它可断言：等待期里的帧分不清是这一拍还是重连发的。
    static func shouldOpenOnRetry(openInFlight: Bool, established: Bool) -> Bool {
        !openInFlight && !established
    }

    /// 退避到点：把这条流再开一次。
    ///
    /// 号在排这一拍的时候已经换好了。等待期间若连接换过代次（`sendAllOpens` 已经把它开出去），
    /// 这一拍就什么都不做 —— 同一个号重发一次 open 会被网关当成「重复编号」而**关掉连接**。
    private func retryNow(_ key: ObjectIdentifier) {
        guard active, let stream = streams[key] else { return }
        stream.retryWorkItem = nil
        guard Self.shouldOpenOnRetry(openInFlight: stream.openInFlight,
                                     established: established.contains(stream.id)) else { return }
        if task != nil {
            sendOpen(stream)
        } else {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            connect()
        }
    }

    /// 这条流是否排着一拍退避。对测试可读：它是「退避真的排上了」的唯一观测点，
    /// 与 `streamId(of:)` 同一条理由 —— 流表不该为了断言敞开。
    func isWaitingToRetry(owner: AnyObject) -> Bool {
        streams[ObjectIdentifier(owner)]?.retryWorkItem != nil
    }

    /// 从表里摘掉一条流。**不发帧** —— 该不该取消由调用方决定：注销要取消，
    /// 服务端已经收尾的那一条不要。
    private func forget(_ key: ObjectIdentifier) {
        guard let stream = streams.removeValue(forKey: key) else { return }
        stream.retryWorkItem?.cancel()
        stream.retryWorkItem = nil
        established.remove(stream.id)
    }

    /// 只清本地登记（不发帧）。代次切换与收尾共用它。
    private func forgetAll() {
        for key in Array(streams.keys) { forget(key) }
    }

    /// 按编号找流。表很小（一条连接上几条），线性扫比维护第二张反查表便宜。
    private func stream(withId id: StreamId) -> (key: ObjectIdentifier, stream: OpenStream)? {
        for (key, stream) in streams where stream.id == id { return (key, stream) }
        return nil
    }

    // MARK: - 收

    private func receiveLoop(on webSocketTask: URLSessionWebSocketTask, generation current: Int) {
        webSocketTask.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.task === webSocketTask else { return }
                switch result {
                case .failure(let error):
                    // 连接死了：清场走退避重连。打印具体原因 —— ATS / LNP /
                    // 路由器隔离都会在这里留下各自的错误码。
                    Log.warn(Log.Module.session, "g\(current) receive failed: \(error)")
                    self.closeTask()
                    self.scheduleReconnect()

                case .success(let message):
                    self.handleMessage(message, generation: current)
                    self.receiveLoop(on: webSocketTask, generation: current)
                }
            }
        }
    }

    /// 一帧到了：解外壳、**按编号归流**、交给订阅方、照它回的那一句话做。
    ///
    /// 对内可见（不 `private`）与 `route` / `noteReply` 同理：这里有一条只能在此处断言的
    /// **顺序** —— 「收到任何东西」先于「按编号归流」。`receiveLoop` 要一条真 socket 才走得到，
    /// 而这段顺序关乎一条健康连接会不会被自己的心跳判死。
    func handleMessage(_ message: URLSessionWebSocketTask.Message, generation current: Int) {
        // 收到任何一帧都是「对端还活着」的证据 —— 由心跳那一拍消费（见 `livenessTick`）。
        // ⚠️ 它**不**等于「这条流已建成」：升级后先到的任何一帧都算「收到过东西」，
        // 而那时打开帧的一大帧可能还在路上 —— 把它当成就绪，心跳会立刻激活、
        // 再在几拍之后把一条正在正常传输的连接判死。
        heardFromPeer = true
        guard case .string(let text) = message else {
            Log.debug(Log.Module.session, "g\(current) non-text frame ignored")
            return
        }
        let rawData = Data(text.utf8)
        guard let frame = try? JSONDecoder().decode(MuxServerEnvelope.self, from: rawData) else {
            Log.warn(Log.Module.session, "g\(current) unparsable frame (first 120 chars): \(text.prefix(120))")
            return // 解不了的帧不是消息，忽略
        }
        Log.debug(Log.Module.session, "g\(current) frame: \(frame.type)")

        let reply = route(frame, raw: rawData)
        noteReply(reply, streamId: frame.streamId)

        // 四个动作只作用于这一条流。判不出是哪一条（没有编号、或编号已不在表里）时
        // 什么都不做 —— 迟到的尾巴不该改变任何东西。
        switch reply.next {
        case .keep:
            break
        case .reopen:
            guard let id = frame.streamId, let found = stream(withId: id) else { return }
            reopen(key: found.key)
        case .retry:
            guard let id = frame.streamId, let found = stream(withId: id) else { return }
            scheduleRetry(found.key)
        case .stop:
            // 终态：这条流再开也是同一个结果。收起它 —— **连接与别的流不动**。
            guard let id = frame.streamId, let found = stream(withId: id) else { return }
            forget(found.key)
        }
    }

    /// 投递口：编号属于哪条流就交给哪条；没有编号的帧交给连接级收货人，不进任何一条流。
    ///
    /// 编号不复用之后，唯一还会带着**别的**编号到达的帧，是上一条流的尾巴（取消之后仍在
    /// 路上的事件帧）。放它们进判读器，最轻是一次没必要的「跳号重开」，最重是用上一个
    /// 会话的窗口覆盖这一屏。无编号的帧不属于流 —— 让某条流代收时，「归谁」就变成了
    /// 登记顺序的问题，而屏幕一关那条流就没了。
    ///
    /// 单独成方法（而不是摊在 `handleMessage` 里）是为了它能被单独断言：它只回答
    /// 「这一帧归不归这条流」，不掺「线还在不在」的那一半（那一半在 `handleMessage`）。
    func route(_ frame: MuxServerEnvelope, raw: Data) -> StreamReply {
        if let id = frame.streamId {
            guard let found = stream(withId: id) else { return StreamReply() }
            return found.stream.subscription.handler(frame, raw)
        }
        unscopedSink?.accept(frame)
        return StreamReply()
    }

    /// 按订阅方的答复更新本层状态 —— 「建成判据由订阅方给、时机在连接层」的可执行版本。
    ///
    /// 建成即退避归零：不归零的话，握手持续失败之后即使终于成功，也会带着爬满的档位继续
    /// 退避 —— 一次成功不该被上一段失败的账拖住。这条流自己的重试档位也归零：
    /// 它已经证明能建成，下一次失败该从最短的等法重新算。
    ///
    /// 单独成方法（而不是摊在 `handleMessage` 里）是为了它能被单独断言：`receiveLoop`
    /// 那条环要一条真 socket 才走得到，而这段迁移是心跳与退避的唯一输入。
    func noteReply(_ reply: StreamReply, streamId replyStreamId: StreamId?) {
        guard reply.establishes, let id = replyStreamId else { return }
        if let found = stream(withId: id) {
            found.stream.openInFlight = false
            found.stream.retryAttempt = 0
        }
        established.insert(id)
        reconnectAttempt = 0
        missedPongs = 0
        phase = .ready
    }

    // MARK: - 发

    /// 发一段已经编好的文本 —— 本方法不拼协议，只负责「在代次与传输都对得上时发出去」。
    private func send(text: String) {
        // 没有连接就什么都没发：不记账，也不假装发过（网关那边同样什么都不会收到）。
        guard let sentTask = task else { return }
        sentFrames.append(text)
        // 发起时的代次与传输要捕捉下来：回调回来时它们可能已经过时。被取代的 send 以取消
        // （-999）告终，而那个回调若还算数，就会把**刚建立的新连接**关掉、再排一次重连 ——
        // 新连接又被下一次重连掐回来，每 2 秒一转、永不恢复。
        let sentGeneration = generation
        sentTask.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, let error else { return }
                guard Self.callbackApplies(generation: sentGeneration,
                                           current: self.generation,
                                           sameTask: self.task === sentTask) else {
                    Log.debug(Log.Module.session, "stale send failure on g\(sentGeneration) ignored (now g\(self.generation)): \(error)")
                    return
                }
                // 握手没完成或连接已死时 send 会在这里失败 —— 这是
                // 「发了开流内容却收不到任何帧」最常见的原因，必须留痕。
                Log.warn(Log.Module.session, "g\(sentGeneration) send failed: \(error)")
                self.closeTask()
                self.scheduleReconnect()
            }
        }
    }

    // MARK: - 心跳与退避

    private func heartbeat(on webSocketTask: URLSessionWebSocketTask, generation current: Int) {
        Task { [weak self] in
            while let self, self.generation == current, self.task === webSocketTask, self.active {
                try? await Task.sleep(nanoseconds: UInt64(self.pingInterval * 1_000_000_000))
                guard self.generation == current, self.task === webSocketTask else { return }
                // 证据**每拍消费一次**：这一拍收到过就归零，下一拍从零重新记。
                let heard = self.heardFromPeer
                self.heardFromPeer = false
                switch Self.livenessTick(awaitingOpening: self.awaitingOpening,
                                         heardFromPeer: heard,
                                         missed: self.missedPongs,
                                         limit: self.maxMissedPongs) {
                case .probe(let missed):
                    self.missedPongs = missed
                    webSocketTask.sendPing { [weak self] error in
                        Task { @MainActor [weak self] in
                            // pong 回来了（completion 无错即 pong 已达）：对端活着。
                            // 这里只置证据旗，连失数由下一拍消费后清零。
                            if error == nil { self?.heardFromPeer = true }
                        }
                    }
                case .dead:
                    // 半开连接：对面不再回 pong。**必须留痕** —— 这条是「谁掐的」在客户端侧的
                    // 答案（网关侧的对应物见它自己的心跳）。
                    Log.warn(Log.Module.session, "g\(current) heartbeat: no pong in \(self.maxMissedPongs + 1) rounds — closing")
                    self.closeTask()
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    /// 有没有一条流「已发出 open、还没收到开口帧」。
    ///
    /// 心跳让路的只有这一段：大帧正占着 TCP、pong 排在它后面。空闲（一条流也没有）与
    /// 已建成的连接都照常判死 —— 连接常驻之后大部分时间是空闲的，那一段的半开连接
    /// （切网、休眠时收不到 FIN）必须能被发现。
    private var awaitingOpening: Bool {
        streams.values.contains { $0.openInFlight }
    }

    /// 一次心跳节拍的判定结果。
    enum Liveness: Equatable {
        /// 继续探活；`missed` 是本拍之后的连失数（未成流期恒为 0）。
        case probe(missed: Int)
        /// 对面已消失（半开连接）。
        case dead
    }

    /**
     一次心跳节拍的判定 —— 纯函数，与 `backoffDelayMs` 同类：这段编排里不碰 socket 就能断言的部分。

     规则两句话：**有流在等打开帧时不判死；本拍收到过对端的东西就归零。**

     第一条的来由是「收到过任何一帧」这个前置项太弱：升级之后网关**先**发一条审批
     对账帧（它在打开帧之前），心跳会被它当场激活；紧接着打开帧的 1.25 MB 占住整条
     TCP（中继链路上要好几秒），网关的 pong 排在那一大帧**后面**，一拍也到不了 ⇒ 每代连接
     恰好活 6 秒（3 拍，`maxMissedPongs + 1`）就被自己判死。
     **「收到过东西」不等于「这条流已经建成」**，而心跳要判的是后者。

     为什么门槛是「**正在**等打开帧」而不是「还没建成」：连接常驻之后，大量时间根本没有
     流（停在会话列表）。照旧一律不判死，那一段的半开连接就永远发现不了 —— 表现是
     「回到会话详情没有内容，也不重连」。所以空闲段必须判，只有「正在等打开帧」这一段让路。

     没有流在等打开帧的那一段不是没人管：正在等的那段归**就绪硬超时**（45s）——
     「没建起来」与「建起来又死了」是两件事。

     ⚠️ 已知未尽：**已成流之后**若单帧传输超过 6 秒（例如一条很大的工具结果），这条规则仍会判死 ——
     客户端拿不到「对面在忙」这个信息。根治要分片（把一帧拆成多帧，让控制帧能插进分片之间），
     代价是新增一套「窗口未到齐」的状态。现在不做：客户端可请求的会话里触发条件不可达，
     而分片会把一帧的语义拆成多帧、两头都要改。

     - Parameters:
       - awaitingOpening: 本代是否有一条流已发出 open、还没收到打开帧。
       - heardFromPeer: 本拍内是否收到过对端的东西（一帧，或我们 ping 的 pong）。
       - missed: 本拍之前累计的连失数。
       - limit: 允许的最大连失数。
     */
    static func livenessTick(awaitingOpening: Bool, heardFromPeer: Bool, missed: Int, limit: Int) -> Liveness {
        guard !awaitingOpening, !heardFromPeer else { return .probe(missed: 0) }
        let next = missed + 1
        return next > limit ? .dead : .probe(missed: next)
    }

    /**
     迟到的回调该不该起作用 —— 代次与传输**双重相等**才算「本代当前的那条连接」。

     单独一个代次判据不够：同一代之内传输也可能已被替换（`connect` 里的先关后建）。判据松一格，
     一个被取代的 `send` 回调就会把新连接掐掉，而它自己又会再排一次重连。
     */
    static func callbackApplies(generation: Int, current: Int, sameTask: Bool) -> Bool {
        generation == current && sameTask
    }

    /**
     * 重连延迟的纯函数（`random` 注入）—— 曲线与抖动范围是这段编排里唯一**可断言**的行为：不碰
     * socket 就能验证。完整的「断线 → 退避 → 重连 → 代次递增」需要真网络，由真机测试覆盖。
     *
     * 连接级重连与单条流的 `.retry` 共用这条曲线：两者都是「等一等再试」，差别只在
     * 谁被重开（整条连接 / 那一条流），而那个差别不该顺手把等待曲线也分叉成两条。
     *
     * - Parameters:
     * - attempt: 第几次重连（从 1 起）。
     * - random: 抖动采样，`0..<1`。
     */
    static func backoffDelayMs(attempt: Int, random: Double) -> Int {
        // attempt 1 是第一次重连，指数从 2^0 起。
        let exponent = min(max(attempt, 1), 16) - 1
        let cap = min(baseBackoffMs * (1 << exponent), maxBackoffMs)
        return Int(Double(cap) * (0.5 + min(max(random, 0), 1) * 0.5))
    }

    /// 没有票时的那一步：去换，然后按结果安排下一步。
    ///
    /// 三种结果三种走向，**不能合并**：
    /// - 换到 → 立刻重连（跳过这次退避——它挡着的正是刚刚被解决的那个问题）
    /// - 等一等就好（网络不通 / 网关不在）→ 继续退避，状态没坏
    /// - 拿不到且不会自己好（未配对 / 关系被撤销）→ **停**。再试是纯空转：每 10 秒一次、
    ///   静默、永不收敛，而屏幕上什么都不会变。由界面去说「需要重新配对」。
    private func renewThenRetry() {
        guard active else { return }
        // 必须先离开 `.connecting`：这一代没有建出连接，而 `connect` 早在前几步就把
        // phase 置成了 `.connecting`。留着它有两个后果 —— 换到票之后 `reconnectNow`
        // 会以「正在握手」为由拒绝（于是永远连不上），而界面会一直显示「连接中…」。
        // `.idle` 在此刻是准确的：没有连接，也没有排定的重试（下面才决定要不要排）。
        phase = .idle
        guard let ticketRenewer else {
            // 没接换票器（预览 / 单测的裸实例）：退回退避，不假装自己会换。
            scheduleReconnect()
            return
        }
        Task { [weak self] in
            let outcome = await ticketRenewer()
            guard let self, self.active else { return }
            switch outcome {
            case .granted:
                Log.info(Log.Module.session, "ticket renewed — reconnecting now")
                self.reconnectNow()
            case .retryLater:
                self.scheduleReconnect()
            case .unavailable:
                Log.warn(Log.Module.session, "no ticket and none obtainable — stopping the follow loop")
                self.phase = .idle
            }
        }
    }

    /// 退避重连 —— 延迟由 `backoffDelayMs` 决定。
    private func scheduleReconnect() {
        guard active else { return }
        // 单飞：本拍取代尚未触发的那一拍。不取代的话两个定时器各起一条连接，后起的那条把先起
        // 的掐死、先起的失败回调再排一次，于是 attempt 编号跳着走、退避永远爬不到上限。
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1

        let delay = Self.backoffDelayMs(attempt: reconnectAttempt, random: Double.random(in: 0..<1))

        Log.info(Log.Module.session, "reconnect in \(delay)ms (attempt \(reconnectAttempt))")
        phase = .waiting(ms: delay)
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
    }
}

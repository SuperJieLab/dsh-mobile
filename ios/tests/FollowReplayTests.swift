/**
 * 订阅流下的镜像重放与退避曲线。
 *
 * **重放的形状**：opening 即 `page` 的窗口（`SessionPage`），一条事件帧即一次覆盖到
 * `seq + 1` 的快照（`SessionSnapshot`）。不碰 `SessionSync`、不碰网络，按投喂顺序重放 ——
 * 镜像那台状态机若为 WebSocket 改任何一行，这里先红。
 *
 * **退避曲线**：`FollowClient` 的重连编排需真网络（那部分由真机判据覆盖），这里测它的纯函数
 * 部分 —— 指数爬升、抖动边界、封顶。
 *
 * **打开帧的尺寸纪律**：客户端接收上限与网关承诺上界的关系，以及 `window-too-large` 归入
 * 终态而非重试。真收到拒绝帧后停在 idle 的那段行为链由真机判据覆盖。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class FollowReplayTests: XCTestCase {

    private func event(_ seq: Int, text: String = "m") -> SessionEvent {
        SessionEvent(type: seq % 2 == 0 ? "user/message" : "assistant/message", seq: seq, time: 1_700_000_000_000 + Double(seq), data: .object([:]))
    }

    func testReplayAndBackoff() async {

        // MARK: C3 —— 订阅流按投喂顺序重放进同一台镜像

        var mirror = SessionMirror()

        // ① opening：50 条的尾窗（此处缩成 3 条示意），就是一次 `page` 的形状。
        let openingEvents = [event(2), event(3), event(4)]
        let opening = SessionPage(pageStart: 2, asOfSeq: 5, hasOlder: true, events: openingEvents)
        XCTAssertTrue({
            if case .merged = mirror.open(with: opening) { return true }
            return false
        }(), "C3-1 opening 经 mirror.open 落地（与 page 同一入口）")
        XCTAssertTrue(mirror.cursor == 5 && mirror.pageStart == 2 && mirror.hasOlder, "C3-2 水位与窗口起点由 opening 钉住")

        // ② 事件帧：一条 = 一次覆盖到 seq+1 的快照。重复投递也被幂等吸收。
        let first = mirror.apply(.received(SessionSnapshot(asOfSeq: 6, hasMore: false, events: [event(5)])))
        XCTAssertTrue({
            if case .merged(let added) = first { return added == 1 }
            return false
        }(), "C3-3 事件帧按快照语义追加")
        XCTAssertTrue(mirror.cursor == 6, "C3-4 游标推进到 seq+1")

        _ = mirror.apply(.received(SessionSnapshot(asOfSeq: 7, hasMore: false, events: [event(6)])))
        let replayed = mirror.apply(.received(SessionSnapshot(asOfSeq: 7, hasMore: false, events: [event(6)])))
        XCTAssertTrue({
            if case .caughtUp = replayed { return true }
            return false
        }(), "C3-5 重复投递被幂等吸收（重连竞态的必然后果）")

        // ③ 断线 → 重新 open：新 opening **替换**窗口（不做水位续传）；
        // 断线期间服务端发生了 7..10 的事件，新 opening 覆盖 4..11。
        let rebuildEvents = [event(4), event(5), event(6), event(7), event(8), event(9), event(10)]
        let rebuilt = SessionPage(pageStart: 4, asOfSeq: 11, hasOlder: true, events: rebuildEvents)
        XCTAssertTrue({
            if case .merged = mirror.open(with: rebuilt) { return true }
            return false
        }(), "C3-6 重连后的新 opening 以替换落地")
        XCTAssertTrue(mirror.cursor == 11 && mirror.events.first?.seq == 4, "C3-7 重建后的视图完整覆盖断线期间的事件")
        XCTAssertTrue(mirror.events.count == rebuildEvents.count, "C3-8 替换不累积旧内容（窗口重建，不是追加）")

        // MARK: C1 —— 退避曲线（纯函数）

        // 指数爬升：attempt 1..5 的封顶值依次 500、1000、2000、4000、8000。
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 1, random: 1) == 500, "C1-1 attempt 1 封顶 500ms")
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 2, random: 1) == 1_000, "C1-2 attempt 2 封顶 1s")
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 5, random: 1) == 8_000, "C1-3 attempt 5 封顶 8s")

        // 封顶：指数再大也不超过 10s。
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 30, random: 1) == 10_000, "C1-4 封顶 10s")

        // 抖动：random 0 给封顶的 50%，random 1 给 100%。
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 3, random: 0) == 1_000, "C1-5 抖动下界 = 封顶的 50%")
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 3, random: 0.5) == 1_500, "C1-6 抖动中点")

        // 输入钳制：越界的 attempt 与 random 不产生离谱值。
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 0, random: 1) == 500, "C1-7 attempt 0 按 1 处理")
        XCTAssertTrue(FollowClient.backoffDelayMs(attempt: 3, random: 99) == 2_000, "C1-8 random 越界被钳到 1")

        // MARK: 帧层 typed 解码 —— 对账与容错

        let openingText = """
        {"type":"item","streamId":1,"payload":{"sessionId":"s1","cursor":3,"pageStart":0,"hasOlder":true,
          "events":[
            {"type":"user/message","seq":1,"time":1700000000000,"data":{}},
            {"type":"user/message","seq":"oops","time":1700000000001,"data":{}},
            {"type":"assistant/message","seq":2,"time":1700000000002,"data":{}}
          ]}}
        """
        let openingData = Data(openingText.utf8)

        // 对账基准：旧的 JSONValue 往返路径 —— 代码里已经没有它了，判定在这里留档。
        let routed = try! JSONDecoder().decode(JSONValue.self, from: openingData)
        let legacyEvents: [SessionEvent] = ((routed["payload"]?["events"]?.array) ?? []).compactMap {
            try? JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode($0))
        }

        let decodedOpening = OpeningFrame.decode(openingData)
        XCTAssertTrue(decodedOpening != nil, "G1a opening 帧原文直解成功")
        XCTAssertTrue(decodedOpening?.events == legacyEvents, "G1b 直解与 JSONValue 往返产出逐字一致")
        XCTAssertTrue(decodedOpening?.cursor == 3 && decodedOpening?.pageStart == 0 && decodedOpening?.hasOlder == true,
                      "G1c 外壳字段（cursor/pageStart/hasOlder）一次解码齐备")

        XCTAssertTrue(decodedOpening?.events.count == 2, "G2a 坏事件（seq 非数字）单条跳过")
        XCTAssertTrue(decodedOpening?.events.first?.seq == 1 && decodedOpening?.events.last?.seq == 2,
                      "G2b 好事件保序保留")

        // 非 opening 形状（缺 cursor/events）如实返回 nil —— 路由判据不变。
        let notOpening = Data(#"{"type":"item","streamId":1,"payload":{"type":"user/message","seq":9,"time":1,"data":{}}}"#.utf8)
        XCTAssertTrue(OpeningFrame.decode(notOpening) == nil, "G2c 非 opening 载荷不误判")

        // MARK: 合并闸：批内累计，到点收批

        var gate = RefreshGate()
        XCTAssertTrue(gate.eventArrived() == .openWindow, "G3a 批未开：首个事件开批并调度 flush")
        var accumulated = 0
        for _ in 0..<99 where gate.eventArrived() == .accumulate { accumulated += 1 }
        XCTAssertTrue(accumulated == 99, "G3b 批开着：后续 99 个事件只累计，不重复调度")
        XCTAssertTrue(gate.flushDue(), "G3c 到点收批：本批开着 → flush 落地一次")
        XCTAssertTrue(!gate.flushDue(), "G3d 收批之后再 flush 是无事发生（无消费者的重算被挡掉）")
        XCTAssertTrue(gate.eventArrived() == .openWindow, "G3e 关批后新事件重新开批")

        // MARK: 端点生命周期 —— 不存在 → activate 一次 → 存在

        // K1：未激活的 client 不持有端点，op 立抛 .notActivated（transport 尚不存在，零网络）。
        let bare = GatewayClient()
        var k1Hit = false
        do { _ = try await fetchSessions(bare) } catch GatewayClientError.notActivated { k1Hit = true } catch {}
        XCTAssertTrue(k1Hit, "K1 未激活 op 立抛 notActivated（不猜地址、不发网络）")
        XCTAssertTrue(bare.baseURL == nil, "K1b 未激活端点为 nil")

        // K2：activate 是端点唯一来源 —— 激活后同 op 的失败是传输层（refusal），
        // 不再是 notActivated。
        let activated = GatewayClient()
        let endpoint = URL(string: "http://127.0.0.1:1")!
        activated.activate(session: .shared, baseURL: endpoint)
        XCTAssertTrue(activated.baseURL == endpoint, "K2a 激活后端点 = activate 入参")
        var k2Hit = false
        do { _ = try await fetchSessions(activated) } catch GatewayClientError.notActivated { k2Hit = false } catch GatewayClientError.transport { k2Hit = true } catch {}
        XCTAssertTrue(k2Hit, "K2b 激活后失败降为传输层错误（端点确实来自 activate）")

        // K3：无端点时订阅流不建连——直接进退避等待，激活后下一轮自愈。
        let follow = FollowClient()
        follow.baseURLProvider = { nil }
        var lastPhase: FollowClient.Phase?
        follow.onPhaseChange = { lastPhase = $0 }
        follow.start(sessionId: "s1")
        XCTAssertTrue({
            if case .waiting = lastPhase { return true }
            return false
        }(), "K3 无端点建连请求 → 不产连接任务，进入退避等待（激活后自愈）")
    }

    /// 让出若干次，让 `FollowClient` 里那些 `Task { }` 真正跑完。
    ///
    /// ⚠️ **不能写成 `for _ in 0..<N where 条件`**：`where` 只跳过不满足的那一轮、不会让出，
    /// 于是「条件是某种已达成的状态」时一次都不让出，被测的异步任务根本没机会跑 ——
    /// 断言于是落在初始状态上，恒真。等待要按**次数**给，不按**状态**给。
    private func settle(_ rounds: Int = 50) async {
        for _ in 0..<rounds { await Task.yield() }
    }

    /// 手上没有票时不发起握手，而是去换一张 —— 换到了立刻连上。
    ///
    /// 判据盯的是**有没有发生握手**：裸连那一版也会进退避等待（K3 的形态），所以只看
    /// `phase` 分不开两种写法。这条用 `sessionProvider` 是否被调用来当「起了握手」的证据。
    ///
    /// 为什么这比「慢一次」严重：退避重连这条路上没有任何东西会换票。裸连的话，票过期后
    /// 每一轮退避都是同一个 401，**永不收敛** —— 表现为静默断流，直到有人回前台。
    func testNoTicketMeansNoHandshakeThenReconnectOnceRenewed() async {
        let follow = FollowClient()
        follow.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        // 第一次问到票时还没有，换完之后才有 —— 这正是冷启动与票过期的那一刻。
        var ticket: String?
        follow.authorizationProvider = { ticket }
        var handshakes = 0
        follow.sessionProvider = {
            handshakes += 1
            return .shared
        }
        var renewals = 0
        follow.ticketRenewer = {
            renewals += 1
            ticket = "fresh"
            return .granted("fresh")
        }

        follow.start(sessionId: "s1")
        XCTAssertEqual(handshakes, 0, "没有票就不该发握手 —— 那一发必定 401")

        await settle()
        XCTAssertEqual(renewals, 1, "应当去换一次票")
        XCTAssertEqual(handshakes, 1, "换到之后应当立刻重连（跳过剩下一整轮退避）")
        follow.stop()
    }

    /// 换不到、且**不会自己好**（未配对 / 关系被撤销）→ 停止重试。
    ///
    /// 这一条防的是「无限空转」：每 10 秒一轮、静默、永不收敛，而屏幕上一个字都不会变。
    func testAnUnobtainableTicketStopsTheLoopInsteadOfRetryingForever() async {
        let follow = FollowClient()
        follow.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        follow.authorizationProvider = { nil }
        var handshakes = 0
        follow.sessionProvider = {
            handshakes += 1
            return .shared
        }
        follow.ticketRenewer = { .unavailable }

        follow.start(sessionId: "s1")
        await settle()

        XCTAssertEqual(handshakes, 0, "始终没有票 → 一次握手都不该发生")
        XCTAssertEqual(follow.phase, .idle, "拿不到且不会自愈 → 停在 idle，而不是留在退避里")
        follow.stop()
    }

    /// 换不到但状态没坏（网络不通）→ 继续退避，不停止。
    func testARetryableFailureKeepsBackingOff() async {
        let follow = FollowClient()
        follow.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        follow.authorizationProvider = { nil }
        follow.sessionProvider = { .shared }
        follow.ticketRenewer = { .retryLater }

        follow.start(sessionId: "s1")
        await settle()

        XCTAssertEqual({ if case .waiting = follow.phase { return true }; return false }(), true,
                       "暂时换不到 → 留在退避等待里，退避自己会再来一轮")
        follow.stop()
    }

    /// 有票时照常握手 —— 上面几条不能靠「永远不连」通过。
    func testWithATicketTheHandshakeHappens() async {
        let follow = FollowClient()
        follow.baseURLProvider = { URL(string: "http://127.0.0.1:1")! }
        follow.authorizationProvider = { "ticket" }
        var handshakes = 0
        follow.sessionProvider = {
            handshakes += 1
            return .shared
        }
        follow.ticketRenewer = { XCTFail("有票却去换票"); return .granted("x") }

        follow.start(sessionId: "s1")

        XCTAssertEqual(handshakes, 1, "有票就该连")
        follow.stop()
    }

    /// 打开帧上限与拒绝的归属。
    ///
    /// 契约的另一半在网关侧：那边承诺打开帧不超过 4 MiB（`DEFAULT_LIMITS.maxOpeningBytes`），
    /// 这边把接收上限取它的两倍，两端因此配套。`window-too-large` 与「不存在 / 读不出来」
    /// 同类 —— 重连不会让那个窗口变小，所以是终态而不是该退避的码。
    func testOpeningSizeCap() {
        XCTAssertTrue(FollowClient.maximumMessageSize == 8 * 1024 * 1024,
                      "O1a 客户端单帧接收上限有据（8 MiB），不是留在默认的 1 MiB")
        XCTAssertTrue(FollowClient.maximumMessageSize > 4 * 1024 * 1024,
                      "O1b 显著大于网关承诺的 4 MiB 上界（两端配套）")

        XCTAssertTrue(FollowClient.isTerminal(code: GatewayErrorCode.windowTooLarge.rawValue),
                      "O2a window-too-large 是终态（重连只会再收到同一个超界窗口）")
        XCTAssertTrue(FollowClient.isTerminal(code: GatewayErrorCode.unknownSession.rawValue),
                      "O2b 既有终态语义不变：会话不存在")
        XCTAssertTrue(FollowClient.isTerminal(code: GatewayErrorCode.unreadableSession.rawValue),
                      "O2c 既有终态语义不变：日志读不出来")
        XCTAssertFalse(FollowClient.isTerminal(code: GatewayErrorCode.internalError.rawValue),
                       "O2d 其余拒绝仍然退避重连")
        XCTAssertFalse(FollowClient.isTerminal(code: "some-future-code"),
                       "O2e 未知码按可重试处理 —— 新码不该让会话卡死")
    }

    /// 心跳判据与迟到回调的代次隔离。
    ///
    /// 把「打不开」修好之后露出的新症状：连接每 **2.02 秒**一转（= 一个 `pingInterval`），
    /// `reconnect` 的 attempt 爬到 9 且编号跳着走 —— 成因在「状态没按代次隔离」上。第三次复验
    /// （两端日志第一次同时到齐）逼出第二个成因：心跳的**证据**取得太弱。两处都与尺寸无关，
    /// 但同样让会话进不去 —— 两者都属于「不出现连接反复断开」这条要求。
    func testConnectionLivenessScope() {
        // ① 心跳只在**已建成的流**上判死。升级后网关**先**发一条 approval 对账帧
        // （网关升级后先发对账帧），它比 opening 早到；「收到过任何一帧就够格计数」这条规则于是
        // 被它当场激活 —— 而 opening 的 1.25 MB 正堵着这条 TCP，网关的 pong 排在那一大帧
        // **后面**，一拍也到不了 ⇒ 每代连接恰好活 6 秒（3 拍）就被自己判死
        //（真机：`g2 heartbeat: no pong in 3 rounds — closing`，connect 后 6.15 秒）。
        XCTAssertTrue(FollowClient.livenessTick(established: false, heardFromPeer: true, missed: 0, limit: 2) == .probe(missed: 0),
                      "O7a 未成流：收到过东西也不计数 —— 先到的 approval 对账帧不该够格激活心跳")
        XCTAssertTrue(FollowClient.livenessTick(established: false, heardFromPeer: true, missed: 9, limit: 2) == .probe(missed: 0),
                      "O7b 未成流：连失账一并归零 —— 上一代的欠账不继承（真机里每一代都因此死在第一拍）")
        XCTAssertTrue(FollowClient.livenessTick(established: true, heardFromPeer: true, missed: 9, limit: 2) == .probe(missed: 0),
                      "O7c 已成流但本拍收到过东西：归零 —— 对端在给我们发东西，它就是活的")
        XCTAssertTrue(FollowClient.livenessTick(established: true, heardFromPeer: false, missed: 0, limit: 2) == .probe(missed: 1),
                      "O7d 已成流且本拍什么都没收到：第 1 拍连失 1")
        XCTAssertTrue(FollowClient.livenessTick(established: true, heardFromPeer: false, missed: 1, limit: 2) == .probe(missed: 2),
                      "O7e 第 2 拍连失 2，仍在容错内")
        XCTAssertTrue(FollowClient.livenessTick(established: true, heardFromPeer: false, missed: 2, limit: 2) == .dead,
                      "O7f 连失到上限判死 —— 半开连接仍会被发现")

        // ② 迟到回调：代次或传输任一不等即不适用 —— 它不得关掉当前连接、不得再排重连。
        XCTAssertTrue(FollowClient.callbackApplies(generation: 7, current: 7, sameTask: true),
                      "O5a 本代当前的连接：回调算数")
        XCTAssertTrue(!FollowClient.callbackApplies(generation: 6, current: 7, sameTask: false),
                      "O5b 上一代的回调：不算数（否则它会把刚建立的新连接掐掉，自锁成 2 秒一转）")
        XCTAssertTrue(!FollowClient.callbackApplies(generation: 7, current: 7, sameTask: false),
                      "O5c 同代但传输已被替换：同样不算数")

        // O6：就绪硬超时由「网关承诺的打开帧上界 ÷ 实测最慢吞吐」定出来，不是抄上游的 15s ——
        // 抄 15s 的那个版本在真机上活不过 1.25 MB 的打开帧（慢链路要 ~10 秒，且 4 MiB 上界
        // 的最坏情况更久）。判据钉住的是「这个关系」，不是某个魔法数。
        let worstCaseSeconds = Double(4 * 1024 * 1024) / (125 * 1024) // 4 MiB ÷ 125 KB/s ≈ 33.6s
        XCTAssertTrue(FollowClient.readyTimeout >= worstCaseSeconds,
                      "O6a 就绪硬超时应覆盖最慢链路上传完承诺上界所需的时间（否则大窗口必被自己掐断）")
        XCTAssertTrue(FollowClient.readyTimeout == 45, "O6b 取值 = 33.6s + 建连 ~2s，取整到 45s")
    }
}

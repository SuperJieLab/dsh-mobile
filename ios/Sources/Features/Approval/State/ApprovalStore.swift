/**
 * 待答审批的宿主：持表、发布给界面、把一次应答的三种结局翻成卡片状态。
 *
 * 判定在 `ApprovalTable`，这里只剩三件事：把帧转给表并发布结果、把「去答一个」发出去
 * （在途守卫 + 幂等键）、按结局改状态与说明。它与 App 同寿 —— 停在会话列表时表照样在长。
 *
 * 每次应答都带客户端生成的 `answerId`：回包丢了重试，网关回放第一次的结果，绝不二次投递。
 */
import Combine
import Foundation

/// 发一次应答。收成一行是为了三种结局能被分别注入 —— 它们只在网络那一层分得开，
/// 而「卡留不留、说明什么」全按结局分支。
@MainActor
protocol ApprovalAnswering {
    func answer(eventId: String, allow: Bool, answerId: String) async throws
}

/// 生产实现：走既有的一次 HTTP 应答。
///
/// `ok` 只意味着**已投递**，权威结果以流里的 `approval/decided` 为准。失败如实上抛：
/// `unknown-approval` 表示这条审批已经不在了。
@MainActor
struct GatewayApprovalAnswerer: ApprovalAnswering {
    let client: GatewayClient

    func answer(eventId: String, allow: Bool, answerId: String) async throws {
        let _: ApprovalAnswerResponse = try await client.perform(
            ApprovalAnswerRequest(
                eventId: eventId, decision: allow ? "allow" : "deny", answerId: answerId
            )
        )
    }
}

@MainActor
final class ApprovalStore: ObservableObject, UnscopedFrameSink {

    /// 一张卡的应答进展。没有这一项 = 还没动过（也就可以按）。
    enum AnswerState: Equatable {
        /// 请求已发出、回包还没到。
        case sending
        /// 已发出但结果未知（传输失败）—— 卡留着，等上游结算。
        case unknown
        /// 服务端拒了这次投递，附人话说明 —— 那个问题仍挂在网关的暂存里。
        case refused(String)
    }

    /// 表本身发布出去：它一变，读它的视图就重算。不另存一份镜像 ——
    /// 两份数据会有「谁先更新」的问题，而这里没有第二个写者。
    @Published private var table = ApprovalTable()
    @Published private(set) var states: [String: AnswerState] = [:]
    /// 每个会话最近一句话（「已投递」「这条已经不在了」）。新卡到达即清 —— 说明讲的是上一件事。
    @Published private(set) var notices: [String: String] = [:]

    private let answerer: any ApprovalAnswering

    init(answerer: any ApprovalAnswering) {
        self.answerer = answerer
    }

    /// 某个会话还挂着的卡，按到达顺序。
    func pending(in sessionId: String) -> [ApprovalTable.Entry] {
        table.pending(in: sessionId)
    }

    func state(for identity: String) -> AnswerState? {
        states[identity]
    }

    func notice(for sessionId: String) -> String? {
        notices[sessionId]
    }

    /// 两处接线一次接完：无编号帧的收货人、源失效清空。
    ///
    /// 两处各自能单独坏，而且坏了都不编译失败 —— 症状分别是「审批永不显示」与
    /// 「网关的上游没了之后留着一张按不动的卡」。
    ///
    /// 这里没有「换连接代次清空」这一条：清空由服务端的名单帧触发（见 `receive`）。
    /// 挂在客户端「开始连」上是错的 —— 一次连不上的重试会把卡片清掉，而那正是离线
    /// 期间用户唯一能看见的东西。
    func attach(feed: any UnscopedFrameFeed, events: ConnectionEvents) {
        feed.unscopedSink = self
        events.onGeneration { [weak self] generation in
            guard generation == nil else { return }
            self?.clear()
        }
    }

    /// 连接层送来的无编号帧。只认审批，其余一概不看 —— 连接层不认识帧类型，
    /// 分类在这一层做。
    func accept(_ frame: MuxServerEnvelope) {
        guard frame.type == "approval", let payload = frame.payload else { return }
        receive(payload)
    }

    /// 网关推来的一条 `approval` 载荷。
    ///
    /// 名单帧（`sync`）是**重建的界线**：服务端每次连接都先发它、再逐条重投，所以收到
    /// 它就说明「手里这份到此为止，接下来这份是完整的」。名单内容本身不读 —— 谁的卡
    /// 该留着，由「清空 + 重投」回答，不由客户端比对两份名单回答。
    func receive(_ payload: JSONValue) {
        if payload["kind"]?.string == "sync" {
            clear()
            return
        }
        table.absorb(payload)
        if payload["kind"]?.string == "request", let sessionId = payload["sessionId"]?.string {
            // 新的一问来了，上一句说明（「已投递」/「已经不在了」）讲的是别的事。
            notices[sessionId] = nil
        }
        pruneStates()
    }

    /// 连接代次换了，或网关的上游没了：手里的项一条都答不了。之后由网关重投重建。
    func clear() {
        table.clear()
        states.removeAll()
        notices.removeAll()
    }

    /// 应答一张卡。守卫只看「有没有状态」—— 在途、未知、被拒的那一张都不再发第二次。
    func answer(_ entry: ApprovalTable.Entry, allow: Bool) async {
        guard states[entry.identity] == nil else { return }
        // 发出之前就置位：写在回包之后的话，等待期间守卫是空的，连点两次会发两次。
        states[entry.identity] = .sending
        // 收尾统一在这一处：三个出口都要清掉已不在表里的状态行，早退的那两个
        // 漏掉时，下一张同身份的卡会因为「已经有状态」而按不动。
        defer { pruneStates() }
        do {
            try await answerer.answer(
                eventId: entry.eventId, allow: allow, answerId: UUID().uuidString
            )
            // 上游先摘掉自己的投递再广播取消 —— 应答者收不到自己的收口帧，等就是永远等。
            settle(entry, notice: ApprovalStore.deliveredNote(allow: allow))
        } catch GatewayClientError.refused(let failure)
            where failure.code == GatewayErrorCode.unknownApproval.rawValue {
            // 这条已经不在了：留着就是一张永远按不动的卡。
            settle(entry, notice: failure.readableDescription)
        } catch GatewayClientError.refused(let failure) {
            // 服务端拒了这次投递，问题仍挂着 —— 卡留着并写明原因。
            states[entry.identity] = .refused(failure.readableDescription)
        } catch {
            // 传输失败 ≠ 未生效：如实转「未知」，等上游结算。
            states[entry.identity] = .unknown
        }
    }

    /// 结局已定：撤卡、写一句说明。
    ///
    /// 等待期间这一条可能已被上游的 `cancel` 撤掉（那时状态行也跟着清空了）——
    /// 卡都不在了，这句话就成了没有指代的一句，所以只在它仍是自己那一张时才写。
    private func settle(_ entry: ApprovalTable.Entry, notice: String) {
        table.remove(identity: entry.identity)
        guard states[entry.identity] == .sending else { return }
        states[entry.identity] = nil
        notices[entry.sessionId] = notice
    }

    /// 清掉已不在表里的状态行。
    private func pruneStates() {
        let live = Set(table.entries.map(\.identity))
        states = states.filter { live.contains($0.key) }
    }
}

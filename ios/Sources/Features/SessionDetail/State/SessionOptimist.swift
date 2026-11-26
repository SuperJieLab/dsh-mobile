/**
 * 一屏的乐观行：已经发出去、还没被持久事件认领的那几行，以及「持久行已经上屏」的记账。
 *
 * 消费者是 `SessionSync`（发送时插入、视图读数合并、整段重建时清账）与投影的三条直连
 * （打开帧的持久行、落定消息的认领、物化完成后的退休）。
 *
 * 三件事必须同处一处：行的插入与它的锚点（算锚点与插行之间 `frontier` 变了就错位）、
 * 记账与退休（记了不撤 = 那一行永久留在屏上；没记就撤 = 刚发的消息消失一帧）。
 */

import Foundation

@MainActor
@Observable
final class SessionOptimist {

    /// 一行乐观消息的本体。
    ///
    /// **不进 `ConversationAssembler`**：那里的每个输入都要有 `seq`，而这一行还没有 ——
    /// 造一个伪 `seq` 会破坏单调与去重（跳号会被判成缺口，一条本地行会让整条流不可信）。
    struct Entry {
        let requestId: String
        let text: String
        let time: Double
        let anchorSeq: EventOrder

        /// 渲染成一个普通的消息节点 —— 与持久的那一行同一种外观。
        var node: ChatNode {
            ChatNode(key: "pending:\(requestId)",
                     kind: "message",
                     businessId: "pending:\(requestId)",
                     anchorSeq: anchorSeq,
                     visibility: .visible,
                     data: .message(MessageNodeData(text: text, time: time)))
        }
    }

    /// 当前窗口的前沿。锚点取「它减一之后、首块未定稿帧之前」，所以这一刻的值必须现取。
    ///
    /// 必填构造参数而不是可写属性：漏接是编译错误，静默取 0 则新行会落在历史顶部。
    private let frontier: () -> Int

    private(set) var entries: [Entry] = []

    /// 「持久行已经上屏」的行 id —— 退休要等物化那一拍。
    ///
    /// 事件到达时先记账、不删：删早了 `nodes` 会退回旧快照，那条刚发的消息消失一帧。
    /// 只在投影说「这条持久行被接受了」时记账 —— 跳号时持久行进不了视图，那一行要留着。
    private var settled: Set<String> = []

    /// 锚点的序号（只增不减）。用 `entries.count` 会让「先发的那条退休后再发一条」撞回同一个锚点。
    private var ordinal = 0

    init(frontier: @escaping () -> Int) {
        self.frontier = frontier
    }

    var count: Int { entries.count }

    // MARK: - 行的进出

    /// 插一行。`text` 与 `time` 由调用方预处理（归一化文本、毫秒时刻）—— 这里只管位置。
    func insert(text: String, requestId: String, time: Double) {
        ordinal += 1
        // 落在最后一条持久事件之后、**首块未定稿帧之前**（那一块是末 seq + 0.5）。
        // 0.001 的步长只用来在连发时保序；同一个 frontier 下 250 条以内不会撞。
        entries.append(Entry(requestId: requestId, text: text, time: time,
                             anchorSeq: Double(max(0, frontier() - 1)) + 0.25
                                 + Double(ordinal) * 0.001))
    }

    /// 撤一行 —— 发送没被受理，或调用方要按号收回。
    func remove(requestId: String) {
        entries.removeAll { $0.requestId == requestId }
    }

    // MARK: - 记账与退休

    /// 打开帧里已经有的持久行：先记账，等物化之后撤（撤早了会空一帧）。
    func noteDurable(_ records: [SessionRecord]) {
        for record in records {
            if let rpcId = record.event.data["source"]?["rpcId"]?.string {
                settled.insert(rpcId)
            }
        }
    }

    /// 落定的用户消息要认领的是哪一行 —— 「是哪一条」由投影判。
    ///
    /// **不校验「有没有这条」**：撤行只能撤存在的行，那一步的校验在 `retire` 的过滤里。
    /// 两处各判一次，等于给同一条规则留两个来源（水位回退那一帧会带一个本地没有的号到达）。
    func noteClaimed(_ rpcId: String) {
        settled.insert(rpcId)
    }

    /// 持久行已经在新快照里了：撤掉同 `rpcId` 的乐观行。**只从投影的「物化完成」那一声调用** ——
    /// 退休与上屏必须同一拍，否则中间那段 `nodes` 退回旧快照，消息消失一帧。
    func retire() {
        guard !settled.isEmpty else { return }
        let retiring = entries.filter { settled.contains($0.requestId) }
        guard !retiring.isEmpty else {
            settled.removeAll()
            return
        }
        let ids = Set(retiring.map(\.requestId))
        entries.removeAll { ids.contains($0.requestId) }
        settled.subtract(ids)
        Log.info(Log.Module.session, "optimistic prompt retired by its durable message",
                 ["count": String(retiring.count)])
    }

    /// 整段重建：只清「已上屏待退休」那本账，**行本身留着**（用户刚发、宿主还没回应，
    /// 清掉它等于让那行消息凭空消失）。`ordinal` 同理只增不减。
    func clearSettled() {
        settled.removeAll()
    }
}

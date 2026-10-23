/**
 * 待答审批的表：按会话分组存着「还挂着的项」，随帧增删，不随界面生死。
 *
 * 纯值类型，不认识客户端、连接与界面 —— 喂它一条 `approval` 载荷，它回答「现在挂着哪几条、
 * 分别属于哪个会话」。它是卡片唯一的来源：会话日志不参与建卡。
 *
 * **两个动作改变它**：收下（`absorb`）与移除（`remove` / `clear`）。收下按身份覆盖，
 * 于是重连重投不产生第二张卡；移除的两种寻址各有来处 —— `cancel` 只给 `eventId`，
 * 本地作答知道身份。
 *
 * 身份是 `callId ?? eventId`。`eventId` 是「这一次投递」的地址，上游每派发一次就新造一个；
 * `callId` 才是「同一问」。按 `eventId` 建卡的话，一次换代重投就让一张卡变两张。
 */
import Foundation

struct ApprovalTable {

    /// 一条还挂着的审批 —— 卡上要显示的东西全在这里，没有别处可补。
    struct Entry: Identifiable, Equatable {
        /// 同一问的身份：`callId` 优先，没有它才用投递编号。
        let identity: String
        /// 属于哪个会话 —— 分组键，来自帧自己。
        let sessionId: String
        /// 应答的线上地址（这一次投递的）。
        let eventId: String
        let toolName: String
        let reason: String?

        var id: String { identity }
    }

    /// 按到达顺序 —— 审批是串行的，先到的那条排在前面。
    private(set) var entries: [Entry] = []

    /// 收下一条 `approval` 载荷。`request` 按身份覆盖或追加；`cancel` 按 `eventId` 移除；
    /// 其余（对账名单、认不出的种类）不动表。
    mutating func absorb(_ payload: JSONValue) {
        switch payload["kind"]?.string {
        case "request":
            guard let sessionId = payload["sessionId"]?.string, !sessionId.isEmpty,
                  let eventId = payload["eventId"]?.string, !eventId.isEmpty,
                  let toolName = payload["toolName"]?.string, !toolName.isEmpty
            else {
                // 归属或地址读不出来的不建项：没有归属只能放错会话，没有地址的卡按不下去。
                Log.warn(Log.Module.session, "dropped an approval without a session or an address")
                return
            }
            let entry = Entry(
                identity: payload["callId"]?.string ?? eventId,
                sessionId: sessionId, eventId: eventId, toolName: toolName,
                reason: payload["reason"]?.string
            )
            if let index = entries.firstIndex(where: { $0.identity == entry.identity }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        case "cancel":
            guard let eventId = payload["eventId"]?.string else { return }
            remove(eventId: eventId)
        default:
            break
        }
    }

    /// 上游撤回（或别人先答了）：只给得出投递编号。
    mutating func remove(eventId: String) {
        entries.removeAll { $0.eventId == eventId }
    }

    /// 本地作答成功：手里有身份，不必绕回投递编号。
    mutating func remove(identity: String) {
        entries.removeAll { $0.identity == identity }
    }

    /// 网关的上游没了：手里这些一条都答不了，全清。
    /// 之后由网关重投重建 —— 它才是「还挂着什么」的权威。
    mutating func clear() {
        entries.removeAll()
    }

    /// 某个会话还挂着的项，按到达顺序。
    func pending(in sessionId: String) -> [Entry] {
        entries.filter { $0.sessionId == sessionId }
    }
}

/**
 * 待答审批的表：按会话分组存着「还挂着的项」，随帧增删，不随界面生死。
 *
 * 纯值类型，不认识客户端、连接与界面 —— 喂它一条待答调用的载荷，它回答「现在挂着哪几条、
 * 分别属于哪个会话」。它是卡片唯一的来源：会话日志不参与建卡。
 *
 * **两个动作改变它**：收下（`absorb`）与移除（`remove` / `clear`）。收下按身份覆盖，
 * 于是重连重放不产生第二张卡；移除只有一条寻址 —— `eventId`。
 *
 * 身份就是 `eventId`：宿主生成、**跨代稳定**（重放同一批待答项时用的还是它），也是 `cancel`
 * 唯一携带的字段。用别的字段当身份，`cancel` 就删不掉以它建的那一条。
 */
import Foundation

struct ApprovalTable {

    /// 一条还挂着的审批 —— 卡上要显示的东西全在这里，没有别处可补。
    struct Entry: Identifiable, Equatable {
        /// 身份 = 投递编号：宿主生成、跨代稳定，也是 `cancel` 唯一携带的字段。
        let eventId: String
        /// 属于哪个会话 —— 分组键，来自帧的 `agentId`。
        let sessionId: String
        let toolName: String
        let reason: String?

        var id: String { eventId }
    }

    /// 按到达顺序 —— 审批是串行的，先到的那条排在前面。
    private(set) var entries: [Entry] = []

    /// 收下一条待答调用的载荷：按 `eventId` 覆盖或追加。
    ///
    /// 载荷是上游 waterfall 的四个字段原样（`event` / `eventId` / `agentId` / `request`），
    /// 网关只搬不改 —— 所以卡上要的两个字段（工具名、理由）在这一层从 `request` 里取。
    /// 读不出来的不建项：没有归属只能放错会话，没有地址的卡按不下去。
    mutating func absorb(_ payload: JSONValue) {
        guard let eventId = payload["eventId"]?.string, !eventId.isEmpty,
              let sessionId = payload["agentId"]?.string, !sessionId.isEmpty,
              let toolName = payload["request"]?["toolName"]?.string, !toolName.isEmpty
        else {
            Log.warn(Log.Module.session, "dropped an approval without a session or an address")
            return
        }
        let entry = Entry(
            eventId: eventId,
            sessionId: sessionId,
            toolName: toolName,
            reason: payload["request"]?["reason"]?.string
        )
        if let index = entries.firstIndex(where: { $0.eventId == entry.eventId }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// 撤回（或别人先答了）：只给得出投递编号 —— 而它就是身份。
    mutating func remove(eventId: String) {
        entries.removeAll { $0.eventId == eventId }
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

/**
 * 连接级流 `workspace/follow` 的收端：组清单、归档集合与置顶集合。
 *
 * 与 `ControlStream` 同层同形（都折一条连接级流的货物），差别在货物：
 * `session/control` 是投影表，这里是组清单。**七种帧都整份替换或整项增删**，不做
 * 增量合并 —— 组没有可增量合并的稳定身份（顺序会变），合并会把已经删掉的组留在屏上。
 *
 * 这一层只折线上形状：谁是哪个组的、要不要按目录再归并一遍，都不在这里。归属由
 * `items[].sessionIds` 直接给出（`SessionOwners` 折成一张表），客户端不重算。
 */
import Foundation

@MainActor
final class WorkspaceStream {

    /// 组清单或两个集合变了一次。**只给表，不给具名口** —— 订阅面在
    /// `Features/SessionList/State/WorkspaceListSink.swift` 里自己挂。
    let updateListeners = ListenerTable<Void>()

    /// 组清单，顺序即显示顺序（宿主给的注册顺序，`order` 帧校正）。
    private(set) var workspaces: [WorkspaceView] = []
    /// 已归档的会话。客户端目前只在收端保留它，列表的可见性规则不读它。
    private(set) var archivedSessionIds: Set<String> = []
    /// 置顶的会话，最近置顶的在前。
    private(set) var pinnedSessionIds: [String] = []

    private var stream: LogicalStream?
    private var detached = false

    init() {}

    /// 登记这条流。一次只造一条（造流不幂等）；被终态拒绝之后可以再挂。
    func attach(to factory: any StreamFactory) {
        guard stream == nil || detached else { return }
        detached = false
        stream = factory.makeStream(self)
    }

    func handle(_ frame: InboundFrame) -> StreamReply {
        switch frame.type {
        case "item":
            // 货物只在这一层按组流的形状解 —— 连接层不认 `baseline` 的语义。
            guard let raw = frame.value else {
                Log.warn(Log.Module.gateway, "workspace item has no value (payload shape rejected)")
                return StreamReply()
            }
            switch WorkspaceItem.read(raw) {
            case .decoded(let item):
                let establishes = apply(item)
                return StreamReply(establishes: establishes)
            case .unparsable:
                Log.warn(Log.Module.gateway, "workspace item unparsable (payload shape rejected)")
                return StreamReply()
            case .foreign(let type):
                Log.warn(Log.Module.gateway, "dropped an item type this stream does not take",
                         ["type": type ?? "?"])
                return StreamReply()
            }

        case "error":
            guard let failure = frame.failure else { return StreamReply(next: .stop) }
            Log.warn(Log.Module.gateway, "workspace stream refused",
                     ["error": failure.code, "reason": failure.message])
            if !failure.isRetryable { detached = true }
            return StreamReply(next: failure.isRetryable ? .retry : .stop)

        case "end":
            return StreamReply(next: .reopen)

        default:
            return StreamReply()
        }
    }

    /// 一种货物落到状态上。返回它是否意味着「这条流从此刻建成」—— 只有 `baseline` 是。
    ///
    /// `replace` 不是：它是同一代里的一次整份替换，重连后的开口帧才是 `baseline`。
    private func apply(_ item: WorkspaceItem) -> Bool {
        var establishes = false
        switch item {
        case .baseline(let baseline):
            replaceAll(with: baseline)
            establishes = true
        case .replace(let baseline):
            replaceAll(with: baseline)
        case .upsert(let view):
            // 顺序由 `order` 帧校正；这里只保证「同一个组只有一项」。
            if let index = workspaces.firstIndex(where: { $0.workspaceId == view.workspaceId }) {
                workspaces[index] = view
            } else {
                workspaces.append(view)
            }
        case .remove(let workspaceId):
            workspaces.removeAll { $0.workspaceId == workspaceId }
        case .order(let workspaceIds):
            reorder(workspaceIds)
        case .archived(let sessionIds):
            archivedSessionIds = Set(sessionIds)
        case .pinned(let sessionIds):
            pinnedSessionIds = sessionIds
        }
        updateListeners.fire(())
        return establishes
    }

    /// 整份替换。**同一 `workspaceId` 只留第一次出现的那一项。**
    ///
    /// 宿主不该给出重复 id（注册表按 id 索引），但这一层收的是对端的字节：真出现重键时
    /// 留两份会让列表画出两个同身份的组（`Identifiable` 的身份重复，SwiftUI 行为未定义），
    /// 而 `order` 帧要按 id 建索引 —— 那条路上重复键是 `Fatal error`。去重把「不可能」
    /// 变成「不可能崩」：坏数据最多让一个组少一项，不会让 App 退出。
    private func replaceAll(with baseline: WorkspaceBaseline) {
        var seen: Set<String> = []
        workspaces = baseline.items.filter { seen.insert($0.workspaceId).inserted }
        archivedSessionIds = Set(baseline.archivedSessionIds)
        pinnedSessionIds = baseline.pinnedSessionIds
    }

    /// 按 `order` 帧重排。**帧里没提到的组保留在末尾**，不丢 —— 丢一组的表现是
    /// 「这个组在 Mac 上有、手机上没了」，而顺序错只是顺序错。
    ///
    /// 两处都要去重，理由与 `replaceAll` 同一条：`workspaceId` 是列表的身份，重复一次
    /// 就会画出两个同 id 的组。**不用 `Dictionary(uniqueKeysWithValues:)`** —— 它对重复键
    /// 是 `Fatal error`，而这一层的纪律是「坏帧丢弃并留痕」。
    private func reorder(_ workspaceIds: [String]) {
        var byId: [String: WorkspaceView] = [:]
        for view in workspaces where byId[view.workspaceId] == nil {
            byId[view.workspaceId] = view
        }
        // 帧内重复的 id 只认第一次：`["w-1", "w-1"]` 是坏数据，重复列出就是身份重复。
        var seen: Set<String> = []
        var ordered = workspaceIds.filter { seen.insert($0).inserted }.compactMap { byId[$0] }
        let listed = Set(workspaceIds)
        ordered += workspaces.filter { !listed.contains($0.workspaceId) }
        workspaces = ordered
    }
}

extension WorkspaceStream: StreamBehavior {

    var label: String { "workspace" }

    func build(_ id: StreamId) throws -> String {
        try MuxOpenFrame.workspace(streamId: id).encoded()
    }
}

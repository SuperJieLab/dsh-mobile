/**
 * 会话列表的增量合并：一条变更落到一串行上，只这一个入口。纯值类型，不认识网络与视图。
 *
 * 拉取结果原样采用（那是服务端的承诺），这里只把事件带来的行放到 `updatedAt` 该在的位置；
 * 同一时间的两行，新来的排在前面。可见性、删除、未知 id 都不在这里判。
 */
import Foundation

enum SessionListMerger {

    /// 把一条变更应用到一串行上，返回新的行序。
    static func apply(_ change: SessionListChange, to rows: [SessionSummary]) -> [SessionSummary] {
        switch change {
        case .added(let incoming):
            let merged = merge(incoming, into: rows)
            return place(merged, among: rows)
        case .removed(let id):
            return rows.filter { $0.id != id }
        case .status(let id, let running):
            return rows.map { $0.id == id ? withRunning($0, running) : $0 }
        case .activity(let id, let updatedAt):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return rows }
            let row = rows[index]
            // 时间只前进：乱序到达的旧活动不该把它往下推。

            guard updatedAt > row.updatedAt else { return rows }
            let bumped = withUpdatedAt(row, updatedAt)
            var rest = rows
            rest.remove(at: index)
            return place(bumped, among: rest)
        }
    }

    // MARK: - 行

    /// 事件行叠加到已有行上：它知道的那几格取新的，不知道的保留旧值。
    /// **`title` 缺席也保留旧值**，尽管协议里「缺席」同时表示「无标题」与「投影不可用」。
    private static func merge(_ incoming: SessionSummary, into rows: [SessionSummary]) -> SessionSummary {
        guard let existing = rows.first(where: { $0.id == incoming.id }) else { return incoming }
        return copy(of: existing,
                    title: incoming.title,
                    createdAt: incoming.createdAt,
                    origin: incoming.origin,
                    updatedAt: incoming.updatedAt,
                    running: incoming.running,
                    blank: incoming.blank)
    }

    /// 插到第一个 `updatedAt <= 新值` 的位置；都比它新就排最后。
    private static func place(_ row: SessionSummary, among rows: [SessionSummary]) -> [SessionSummary] {
        var rest = rows
        rest.removeAll { $0.id == row.id }
        let index = rest.firstIndex { $0.updatedAt <= row.updatedAt } ?? rest.endIndex
        rest.insert(row, at: index)
        return rest
    }

    private static func withRunning(_ row: SessionSummary, _ running: Bool) -> SessionSummary {
        copy(of: row, running: running)
    }

    private static func withUpdatedAt(_ row: SessionSummary, _ updatedAt: Double) -> SessionSummary {
        copy(of: row, updatedAt: updatedAt)
    }

    /// 从一行拷一行，只改传进来的那几格；没传的保持原值。
    /// 这是本文件**唯一**一处构造 `SessionSummary` —— 反复抄七个字段时，「没提到的字段该保留」
    /// `nil` 在这里表示「不改」，与 `merge` 的意图逐字一致，但不能用来把一格清成 nil。
    private static func copy(of row: SessionSummary,
                             title: String? = nil,
                             createdAt: Double? = nil,
                             origin: String? = nil,
                             updatedAt: Double? = nil,
                             running: Bool? = nil,
                             blank: Bool? = nil) -> SessionSummary {
        SessionSummary(id: row.id,
                       title: title ?? row.title,
                       createdAt: createdAt ?? row.createdAt,
                       updatedAt: updatedAt ?? row.updatedAt,
                       running: running ?? row.running,
                       blank: blank ?? row.blank,
                       origin: origin ?? row.origin)
    }
}

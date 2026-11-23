/**
 * 连接级流 `session/control` 的收端：全部会话的投影。
 *
 * 与 `$events` 一样是**一条**（上游 Host-wide），消费方按 `sessionId` 挑自己关心的那份。
 * 这一层顺带维护投影表：`projection` 帧只给变了的格（`{key, val}`），而消费方要的是
 * 「更新后的整份」才能算读数 —— 表在这里，拼装也在这一层，消费方不必各自复刻一份。
 *
 * ⚠️ 水位用帧里的 `seq`：上游 `SessionProjectionUpdate.seq` 是**引发变化的那个事件**，
 * 与投影自己的 `asOfSeq` 同向单调但不等值。用作「新旧覆盖」的判据够了（重放与乱序
 * 都会被它挡掉），但它不是投影切点，别拿它去比快照的 `asOfSeq`。
 */
import Foundation

@MainActor
final class ControlStream {

    /// 某个会话的投影更新（整份值 + 水位）。
    /// 投影变化的听众表。**只给表，不给具名口** —— 订阅面在
    /// `Features/SessionDetail/State/SessionSync.swift` 里自己挂。
    let updateListeners = ListenerTable<(String, JSONValue, Int)>()

    /// 每个会话的投影表：`sessionId -> {key: value}`。
    private var tables: [String: [String: JSONValue]] = [:]
    /// 每个会话**最后一条增量帧**的事件 seq。
    ///
    /// 只用来在增量之间排重（同一条流内 `seq` 单调）。**基线不写它** —— 基线的是
    /// `asOfSeq`（投影切点），与事件 seq 不是同一条轴，写进同一个槽会让第一个增量
    /// 被错误地挡掉或被错误地放行。
    private var lastEventSeq: [String: Int] = [:]

    private var stream: LogicalStream?
    private var detached = false

    init() {}

    func attach(to factory: any StreamFactory) {
        guard stream == nil || detached else { return }
        detached = false
        stream = factory.makeStream(self)
    }

    func handle(_ frame: InboundFrame) -> StreamReply {
        switch frame.type {
        case "item":
            // 货物只在这一层按 `session/control` 的形状解 —— 连接层不认 `baseline` 的语义。
            guard let raw = frame.value else {
                Log.warn(Log.Module.gateway, "control item has no value (payload shape rejected)")
                return StreamReply()
            }
            switch ControlValue.read(raw) {
            case .decoded(let value):
                return apply(value)
            case .unparsable:
                Log.warn(Log.Module.gateway, "control item unparsable (payload shape rejected)")
                return StreamReply()
            case .foreign(let type):
                Log.warn(Log.Module.gateway, "dropped an item type this stream does not take",
                         ["type": type ?? "?"])
                return StreamReply()
            }

        case "error":
            guard let failure = frame.failure else { return StreamReply(next: .stop) }
            Log.warn(Log.Module.gateway, "control stream refused",
                     ["error": failure.code, "reason": failure.message])
            if !failure.isRetryable { detached = true }
            return StreamReply(next: failure.isRetryable ? .retry : .stop)

        case "end":
            return StreamReply(next: .reopen)

        default:
            return StreamReply()
        }
    }

    /// 一条已认出的投影货物落到表里。基线整份替换，增量按 `seq` 排重。
    private func apply(_ value: ControlValue) -> StreamReply {
        switch value {
        case .baseline(let blocks):
            for (sessionId, block) in blocks {
                tables[sessionId] = block.values.object ?? [:]
                // 不写水位：`asOfSeq` 与后续增量的 `seq` 不同轴。
                if let values = block.values.object.map(JSONValue.object) {
                    updateListeners.fire((sessionId, values, block.asOfSeq))
                }
            }
            return StreamReply(establishes: true)
        case .projection(let sessionId, let seq, let changes):
            // 增量之间比 `seq`（同一条流内单调）：不前进就是重放或乱序，丢掉。
            if let current = lastEventSeq[sessionId], seq <= current { return StreamReply() }
            var table = tables[sessionId] ?? [:]
            for change in changes { table[change.key] = change.val }
            tables[sessionId] = table
            lastEventSeq[sessionId] = seq
            updateListeners.fire((sessionId, .object(table), seq))
            return StreamReply()
        }
    }
}

extension ControlStream: StreamBehavior {

    var label: String { "control" }

    func build(_ id: StreamId) throws -> String {
        try MuxOpenFrame.control(streamId: id).encoded()
    }
}

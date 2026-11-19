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
    private let updateListeners = ListenerTable<(String, JSONValue, Int)>()

    /// 每个会话的投影表：`sessionId -> {key: value}`。
    private var tables: [String: [String: JSONValue]] = [:]
    /// 每个会话的水位。
    private var watermarks: [String: Int] = [:]

    private var stream: LogicalStream?
    private var detached = false

    init() {}

    func attach(to factory: any StreamFactory) {
        guard stream == nil || detached else { return }
        detached = false
        stream = factory.makeStream(self)
    }

    /// 某个会话的投影变了。回调带**更新后的整份值**与水位。
    @discardableResult
    func onUpdate(_ handler: @escaping (String, JSONValue, Int) -> Void) -> () -> Void {
        updateListeners.add(handler)
    }

    func handle(_ frame: InboundFrame) -> StreamReply {
        switch frame.type {
        case "item":
            guard case .item(.control(let value))? = frame.payload else {
                if frame.payloadRejected {
                    Log.warn(Log.Module.gateway, "control item unparsable (payload shape rejected)")
                }
                return StreamReply()
            }
            switch value {
            case .baseline(let blocks):
                for (sessionId, block) in blocks {
                    tables[sessionId] = block.values.object ?? [:]
                    watermarks[sessionId] = block.asOfSeq
                    if let values = block.values.object.map(JSONValue.object) {
                        updateListeners.fire((sessionId, values, block.asOfSeq))
                    }
                }
                return StreamReply(establishes: true)
            case .projection(let sessionId, let seq, let changes):
                // 水位不前进就是重放或乱序：丢掉，别用旧值盖新值。
                if let current = watermarks[sessionId], seq <= current { return StreamReply() }
                var table = tables[sessionId] ?? [:]
                for change in changes { table[change.key] = change.val }
                tables[sessionId] = table
                watermarks[sessionId] = seq
                updateListeners.fire((sessionId, .object(table), seq))
                return StreamReply()
            }

        case "error":
            guard case .refused(let failure)? = frame.payload else { return StreamReply(next: .stop) }
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
}

extension ControlStream: StreamBehavior {

    var label: String { "control" }

    func build(_ id: StreamId) throws -> String {
        try MuxOpenFrame.control(streamId: id).encoded()
    }
}

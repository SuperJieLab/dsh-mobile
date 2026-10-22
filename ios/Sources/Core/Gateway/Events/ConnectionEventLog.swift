import Foundation

/**
 * 事件流的第一个消费方：把几件「机器上发生了什么」写进日志。
 *
 * 它存在的理由不是「有用」，而是**证明这条流真的通了** —— 界面上今天什么都不因事件改变，
 * 没有它，「Mac 上新建一个会话，手机知道」这件事只能靠抓包看。一次事件一行，参数截断。
 *
 * 它是消费方，不是容器的一部分：容器不认识任何一个事件名，加一类事件只多一次 `on`。
 */
@MainActor
final class ConnectionEventLog {

    /// 与本机会话列表有关的几件事。名字是上游的词汇，网关的白名单原样转发。
    private static let watched = [
        "api-session/added", "api-session/removed", "api-session/status",
    ]

    init(events: ConnectionEvents) {
        for name in Self.watched {
            events.on(name) { args in
                Log.info(Log.Module.gateway, "event \(name) \(Self.brief(args))")
            }
        }
    }

    /// 参数原样编成一段 JSON —— 事件名说得清「发生了什么」，参数说得清「发生在谁身上」。
    ///
    /// 截断到 120 字符：`api-session/status` 带整个状态对象，全文会把日志淹掉。
    private static func brief(_ args: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(args)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.count <= 120 ? text : String(text.prefix(120)) + "…"
    }
}

/**
 * 会话载荷：被一元信封包着、或被流帧包着的那几个形状。
 *
 * 与链路无关 —— 「用哪条链路承载」不改变它们的字段。
 */
import Foundation

/// 列表里的一行 —— 与上游 `SessionSummary` **同名字段、同形状**。
///
/// 网关不再自己拼这一行（它转发宿主的 `session/list`），所以这里的字段就是上游的字段：
/// 少一格、改一个名，手机端的行就会与 Web UI 的行长得不一样。
///
/// **没有 `title` / `createdAt` / `workspaceId`**：
/// - 标题在 `projections.values.title`（见 {@link title}）；
/// - 归属在组流（`workspace/follow` 的 `sessionIds`）；
/// - 上游的摘要本来就不带创建时间。
struct SessionSummary: Decodable, Identifiable, Equatable {
    let sessionId: String
    /// **最后一次用户发言的时间**，没有则等于创建时间。
    /// ⚠️ 不是「最后一次事件的时间」—— 助手输出与工具调用不推进它。
    let updatedAt: Double
    /// 这个会话当前有 agent 在跑吗。
    let running: Bool
    /// 还没有任何 turn 的会话 —— 工作区里那行候补的「新会话」。
    let blank: Bool
    /// 这个会话当前是否持有活着的 agent。
    let agentAvailable: Bool
    /// 只在**非** `current` 时出现（`migration-required`）。
    let formatStatus: String?
    /// 子会话的父会话；普通会话没有这一格。
    let parentSessionId: String?
    /// `"subagent"` 表示它是另一个会话的子会话；普通会话没有这个字段。
    let origin: String?
    /// 会话目录。上游用「有没有 `cwd`」判可见性，所以它随行一起给。
    let cwd: String?
    /// 投影块：`{kind, asOfSeq, values}`。**只有标题这一格被读**，其余原样收下不用。
    let projections: SessionProjections?

    /// `Identifiable` 要的那一格。线上叫 `sessionId`，这里不另起名字。
    var id: String { sessionId }

    /// 标题：投影里的那一格。缺席 = 没有标题（不是故障）。
    var title: String? { projections?.title }
}

/// 一行的投影块 —— 与上游 `SessionProjectionHints` 同形。
///
/// `kind` 是水位所属的序列（`cached` 是持久缓存的切点，`sequenced` 是活会话的事件序列），
/// 两者**不可比**。客户端目前不比较它，只读 `values.title`；留着是因为删掉它会让
/// 「投影有没有到」这件事失去唯一的证据。
struct SessionProjections: Decodable, Equatable {
    let kind: String?
    let asOfSeq: Int?
    let values: JSONValue?

    /// 标题。不是字符串（包括 `null`）一律视为「没有标题」。
    var title: String? { values?["title"]?.string }
}

/// 一条会话事件。协议承诺**事件体原样透传**（不裁剪、不翻译、不改名，且日后会带我们不认识的
/// 字段），所以只声明用到的四个，其余靠 `JSONValue` 原样收下不解析。
struct SessionEvent: Decodable, Equatable {
    let type: String
    let seq: Int
    let time: Double
    let data: JSONValue
    /// 某个事件在「模型可见面」上的动作：追加还是替换。**顶层字段，不在 `data` 里**。
    /// 缺省 = 追加（绝大多数事件都是）。压缩点用它标 `replace`，客户端据此不把它当正文。
    let surfaceOp: JSONValue?

    /// 显式写出 `init`：`let` 的可选属性在合成 init 里**没有默认值**，
    /// 不加这一条，所有 `SessionEvent(type:seq:time:data:)` 的老调用点都会编不过。
    init(type: String, seq: Int, time: Double, data: JSONValue, surfaceOp: JSONValue? = nil) {
        self.type = type
        self.seq = seq
        self.time = time
        self.data = data
        self.surfaceOp = surfaceOp
    }
}


/// 会话地址 —— 带 `kind` 判别字段的联合（上游 `SessionAddress`）。
///
/// 不是裸 `sessionId`：将来加一种地址（`subagent`）时，改的是这一处判别，
/// 而不是每个调用点的字段名。本期只发 `kind: "session"`。
struct SessionAddress: Encodable, Equatable {
    let kind = "session"
    let sessionId: String
}

/// 一屏历史的大小 —— 打开与翻页用**同一组数**。
///
/// 上游的 `HISTORY_PAGE_OPTIONS`：`maxMessages: 500`、
/// `turnWindow{minMessages: 50, minTurns: 2}`。只在这里写一次：两处各写一份，
/// 改一处另一处不会红，症状是「打开的一屏与翻回来的那一页长短不同」。
struct HistoryWindow: Encodable, Equatable {
    struct TurnWindow: Encodable, Equatable {
        let minMessages: Int
        let minTurns: Int
    }
    let maxMessages: Int
    let turnWindow: TurnWindow
    static let standard = HistoryWindow(
        maxMessages: 500,
        turnWindow: TurnWindow(minMessages: 50, minTurns: 2)
    )
}

/// 一屏历史里的一条记录：事件外面包一层判别字段（`{type:"event", event}`）。
///
/// 打开帧的 `records` 与分页应答的 `records` 是**同一个类型** —— 客户端用同一套合并逻辑
/// 吃它们，两处分开声明时，加一格只会在一边加。剥这一层只在这里发生。
struct SessionRecord: Decodable, Equatable {
    let type: String
    let event: SessionEvent
}

/// 会话的元信息，随打开帧原样下发（上游 `SessionWireHeader`，九格）。
///
/// 客户端只读 `id`（串流防护：这一帧属于哪条会话）与 `parentSession` / `origin`
/// （是不是子会话）；其余原样收下不解释 —— `version` 的取值集合上游没有约定。
struct SessionWireHeader: Decodable, Equatable {
    let version: Int
    let id: String
    /// Unix 纪元毫秒。
    let createdAt: Double
    let cwd: String?
    let parentSession: String?
    /// 会话是否含一段 fork 继承来的前缀。
    let isSeeded: Bool
    let origin: String?
    let delegationDepth: Int?
    let agentPreset: String?
}

/// 一屏历史 —— 打开帧与分页应答**共用同一个类型**。
///
/// 三个字段各有分工：`records` 是这一屏；`cursor` 是**含端**的切点（宿主覆盖到哪）；
/// `hasMore` 说更早还有没有。**没有「窗口起点」那一格**：起点由首条记录的 `seq` 给出 ——
/// 服务端不再替我们算一个，两份「这一屏从哪开始」迟早分叉。
struct SessionWindow: Equatable {
    let records: [SessionRecord]
    let cursor: Int
    let hasMore: Bool

    /// 窗口内的事件（剥掉记录外面那层判别字段）。视图只认事件 —— 「这一条是不是事件」
    /// 在解码层已经判过了。
    var events: [SessionEvent] { records.map(\.event) }

    /// 窗口起点：首条记录的 `seq`。空窗口取 `cursor + 1` —— 与「下一个期望的 seq」相等，
    /// 于是「往前翻」没有下界可传，也不该发起。
    var start: Int { records.first?.event.seq ?? cursor + 1 }
}

extension SessionWindow {
    /// 打开帧就是第一屏：三个字段一一对应（`records` 已经是剥层前的形状）。
    init(opening: SnapshotFrame) {
        self.init(records: opening.records, cursor: opening.cursor, hasMore: opening.hasMore)
    }
}

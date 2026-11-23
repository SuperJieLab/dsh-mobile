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


/// 一次快照的结果。`Equatable` 是状态机的需要：`Outcome` 要能比较，
/// 而它装着这个类型。
struct SessionSnapshot: Equatable {
    /// 本次覆盖到的位置（不含）—— 回传它就能拿到「空增量」，是水位不变式的用法。
    let asOfSeq: Int
    /// 服务端是否还有没给完的事件。为真就接着要 —— 单次响应有上限。
    let hasMore: Bool
    let events: [SessionEvent]
    /// 会话的模型基线：**下一轮**将使用的模型。缺省 = 服务端不知道，
    /// 客户端退到目录默认；进会话后的增量走订阅流。
    var model: ModelSelection? = nil
}

/// 一段往回读的窗口。与 `SessionSnapshot` 是两个方向：快照从 `since` 往后走，窗口
/// 从某个位置往回走。打开会话用后者取最近一段，之后用前者追新增 —— 客户端**不需要跨会话记住
/// 任何位置**，冷启动永远从「现在的最新一段」开始。
struct SessionPage: Equatable {
    /// 窗口首个事件的 `seq` —— 即下一次往回翻时的 `beforeSeq`。
    let pageStart: Int
    /// 窗口末尾（不含）。与 `SessionSnapshot.asOfSeq` 同义。
    let asOfSeq: Int
    /// 窗口之前还有事件吗。`false` 表示已经到日志开头。
    let hasOlder: Bool
    let events: [SessionEvent]
}
extension SessionPage {
    /// 由 opening 帧的字段拼出窗口 —— 这条流的打开就是一次「最近一段」的窗口。
    /// `cursor`（订阅流的说法：已读到的位置）与 `asOfSeq`（窗口末尾，不含）是同一个量，
    /// 改名只在这里发生一次。归这里是因为 `asOfSeq` 属于 `SessionPage`：谁持有目标名字，
    /// 谁负责翻译。
    init(opening: OpeningFrame) {
        self.init(pageStart: opening.pageStart,
                  asOfSeq: opening.cursor,
                  hasOlder: opening.hasOlder,
                  events: opening.events)
    }
}

/**
 * 会话载荷：被一元信封包着、或被流帧包着的那几个形状。
 *
 * 与链路无关 —— 「用哪条链路承载」不改变它们的字段。
 */
import Foundation

/// 列表里的一行（协议 v2）。字段全来自会话 header 或 host 已维护的投影，没有一个读日志算出来
/// —— 列表因而零 I/O。
struct SessionSummary: Decodable, Identifiable, Hashable {
    let id: String
    /// **可选**：该会话没有标题、或那一行没有投影可用时，字段**整个缺失** ——
    /// 既不是 `null` 也不是空串。这是契约的一部分，不是故障。
    let title: String?
    /// 会话创建时间。客户端不显示它，但**合并时要保留**（事件推来的行没有这一格）。
    ///
    /// **可选**：列表拉取给出的行都带它，而事件推来的行不带（上游 `api-session/added`
    /// 的 summary 里没有这一格）。合并时事件不得抹掉已知行的那一格。
    let createdAt: Double?
    /// **最后一次用户发言的时间**，没有则等于 `createdAt`。
    /// ⚠️ 不是「最后一次事件的时间」—— 助手输出与工具调用不推进它。
    let updatedAt: Double
    /// 这个会话当前有 agent 在跑吗。
    let running: Bool
    /// 还没有任何 turn 的会话 —— 工作区里那行候补的「新会话」。
    let blank: Bool
    /// `"subagent"` 表示它是另一个会话的子会话；普通会话没有这个字段。
    let origin: String?
}

/// 一条会话事件。协议承诺**事件体原样透传**（不裁剪、不翻译、不改名，且日后会带我们不认识的
/// 字段），所以只声明用到的四个，其余靠 `JSONValue` 原样收下不解析。
struct SessionEvent: Decodable, Equatable {
    let type: String
    let seq: Int
    let time: Double
    let data: JSONValue
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

/**
 * 上下文占用的载荷。与链路无关：一元响应与流帧都可能带它。
 */
import Foundation

/// 占用组成的三项。**不是** `usedTokens` 的分解 —— 估算器对中文与 JSON schema
/// 定价偏低，三项加起来不等于那个数。
struct UsageBreakdown: Decodable, Equatable {
    let systemTokens: Int
    let toolsTokens: Int
    let messageTokens: Int
}

/// 手机上要画的那个比例。

struct UsagePayload: Decodable, Equatable {
    /// 分子。服务端已按「provider 报的数优先，启发式重定价次之」算好，客户端不再自己推。
    let usedTokens: Int
    /// 分母 —— 路由声明的上下文容量。
    let contextWindow: Int
    /// 组成三项。服务端「不知道」时整个缺失 —— 缺它**不减损**上面那个比例。
    ///
    /// ⚠️ 写成带默认值的 `var` 只为构造时能省略：memberwise init 不给 `let` + Optional 隐含缺省。
    var breakdown: UsageBreakdown? = nil
}

/// 一个水位上的一份占用读数。`usage` 缺失是一个**陈述**而不是故障：这个 cut 上没有可显示的
/// 东西，正在显示的旧值应当被清掉。

struct UsageSnapshot: Decodable, Equatable {
    /// 这份读数取自日志的哪个水位。⚠️ 与窗口的 `cursor` 是两条轴，**不要相减** —— 窗口按
    /// 消息数切，可能落后或领先投影折叠到的位置。
    let asOfSeq: Int
    /// 缺省 = 这个水位上没有可显示的东西（构造时可省略，理由同 `UsagePayload.breakdown`）。
    var usage: UsagePayload? = nil
}

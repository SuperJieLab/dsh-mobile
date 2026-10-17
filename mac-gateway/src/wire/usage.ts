/**
 * 两端共守的占用量形状。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Contract/GatewayProtocol.swift`）—— 改字段那边必须同改。
 *
 * 这里**只有形状**：怎么从两个投影值折出一个比值是服务端的算术 —— 读投影键是
 * `upstream/usage.ts` 的事，判断「值变了没有」是 `protocol/usage.ts` 的事。
 * 手机上算不出这件事，所以它只能收到值。
 *
 * `asOfSeq` 是投影的切点，**不是**窗口的水位：窗口按消息数切，可能落后或超前
 * 投影的日志，两者是独立的水位。客户端因此不得拿两个水位相减。
 */

/**
 * 构成的一半：对下一个请求的启发式 system / tools / message 拆分。
 * 刻意**不是** `usedTokens` 的分解 —— 估计器低估 CJK 文本与 JSON schema，
 * 三者相加永远对不齐锚定的分子。
 */
export interface BreakdownValues {
  systemTokens: number
  toolsTokens: number
  messageTokens: number
}

/** 手机所画之物：一个比值，以及它描述多大的上下文。 */
export interface UsagePayload {
  /** 分子：以 provider 为锚，此处绝不估计。 */
  usedTokens: number
  /** 分母。 */
  contextWindow: number
  /**
   * 仅当三部分全部已知且不全为零时存在；缺省省略展开行，绝不省略比值。
   */
  breakdown?: BreakdownValues
}

/**
 * 一个水位加上在该水位下可显示之物。`usage` 缺省是陈述，不是缺口：
 * 正在显示更旧内容的客户端据此清掉它。
 */
export interface UsageSnapshot {
  /** 读到这些值时的切点 —— 日志的水位，不是窗口边界。 */
  asOfSeq: number
  usage?: UsagePayload
}

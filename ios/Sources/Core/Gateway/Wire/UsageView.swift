/**
 * 投影值 → 要画的读数。
 *
 * 规则从网关搬回（`upstream/usage.ts` 的 `usageSnapshotOf`）：分子先取
 * `contextPressure.projectedTokens`、缺则 `pressureTokens`；分母是 `contextWindow`，
 * 必须为正。**两者缺一即「未知」**，不是 0% —— 界面据此隐藏整行。
 *
 * 三部分拆解（`contextBreakdown`）必须三者同时在、且不全为零：残缺的拆解
 * 误导多于告知。
 *
 * 两个键共用一个水位（`asOfSeq`），所以不可能拿新鲜比值配陈旧分解。
 */
import Foundation

enum UsageView {

    /// 一份投影切取 → 读数。`values` 是某个会话的投影键值表。
    static func snapshotOf(_ values: JSONValue, asOfSeq: Int) -> UsageSnapshot {
        UsageSnapshot(asOfSeq: asOfSeq, usage: payloadOf(values))
    }

    /// 只要分子那一份（control 的更新不带投影水位，用这个）。
    static func payloadOf(_ values: JSONValue) -> UsagePayload? {
        let pressure = values["contextPressure"]
        let usedTokens = nonNegativeInteger(pressure?["projectedTokens"])
            ?? nonNegativeInteger(pressure?["pressureTokens"])
        let contextWindow = positiveInteger(pressure?["contextWindow"])
        guard let usedTokens, let contextWindow else { return nil }
        return UsagePayload(
            usedTokens: usedTokens,
            contextWindow: contextWindow,
            breakdown: breakdownOf(values["contextBreakdown"])
        )
    }

    /// 三部分齐备、且不全为零，否则 `nil`。
    private static func breakdownOf(_ values: JSONValue?) -> UsageBreakdown? {
        guard let values,
              let systemTokens = nonNegativeInteger(values["systemTokens"]),
              let toolsTokens = nonNegativeInteger(values["toolsTokens"]),
              let messageTokens = nonNegativeInteger(values["messageTokens"])
        else { return nil }
        if systemTokens == 0 && toolsTokens == 0 && messageTokens == 0 { return nil }
        return UsageBreakdown(systemTokens: systemTokens, toolsTokens: toolsTokens, messageTokens: messageTokens)
    }

    private static func nonNegativeInteger(_ value: JSONValue?) -> Int? {
        guard let int = value?.int, int >= 0 else { return nil }
        return int
    }

    private static func positiveInteger(_ value: JSONValue?) -> Int? {
        guard let int = value?.int, int > 0 else { return nil }
        return int
    }
}

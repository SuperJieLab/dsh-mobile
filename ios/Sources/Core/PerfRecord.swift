import Foundation

/**
 * 性能记录（R8 期1）—— 与网关 `mac-gateway/src/perf.ts` 的 `PerfRecord` 同构：
 * `seg` / `t` / `sessionId` / `seq` 是公共字段，其余按 seg 不同（iOS 侧只产
 * `dev` 与 `clock` 两种）。字段集与语义是两端契约，见
 * `dev/features/R8-e2e-latency-bench/plans/R8-1-observability-budget.md` 节四；
 * 本类型只负责形状与序列化，段间算术是期2 分析层的事。
 *
 * 缺的字段整个缺席，不填默认值 —— 「这一条不适用」与「值为零」是两件事。
 */
struct PerfRecord {

    /// 记录来自哪一端 —— 契约的四个 seg 值（iOS 侧只写 `dev` / `clock`）。
    enum Seg: String {
        case gw, dev, res, clock
    }

    /// 附加字段的值只有数与文本两种；时间戳一律数以 epoch ms 计。
    enum FieldValue {
        case number(Double)
        case text(String)
    }

    let seg: Seg
    /// 该边界的本地 ms 时刻（epoch ms）。
    let t: Double
    let sessionId: String?
    let seq: Int?
    /// 按 seg 不同的附加字段（devRecv / devApply / serverTime / conn / kind…）。
    let fields: [String: FieldValue]

    init(seg: Seg, t: Double, sessionId: String? = nil, seq: Int? = nil, fields: [String: FieldValue] = [:]) {
        self.seg = seg
        self.t = t
        self.sessionId = sessionId
        self.seq = seq
        self.fields = fields
    }

    /// 当下时刻的 epoch ms —— 埋点调用点取边界时刻用。
    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// 记录的 JSON 字典形状。消费方按字段名读，不依赖键序。
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["seg": seg.rawValue, "t": t]
        if let sessionId { object["sessionId"] = sessionId }
        if let seq { object["seq"] = seq }
        for (key, value) in fields {
            switch value {
            case .number(let number): object[key] = number
            case .text(let text): object[key] = text
            }
        }
        return object
    }

    /// 序列化成一行的 JSON 部分；形状不合法（不可能）时返回 nil，调用方据此不写行。
    var jsonString: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject()),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}

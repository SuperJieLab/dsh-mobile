/**
 * 引擎吃的输入形状 —— 事件 + 一个可用于排序的序号。
 *
 * 排序键是 `Double` 而不是协议的 `Int`：未定稿帧在定稿前没有 `seq`，客户端给它编一个落在
 * 「最后一条持久事件之后、下一条之前」的小数（见 `TransientChannel`）。协议侧的 `seq` 仍是整数，
 * 两种数在这里分开：`order` 只用于排序与定位，`seq` 只在真的有持久事件时才有值。
 */
import Foundation

struct AssemblyEvent: Equatable {
    /// 排序键。持久事件等于 `Double(seq)`，未定稿帧是 `cursor` 与 `cursor+1` 之间的小数。
    let order: Double
    /// 持久事件的协议序号。未定稿帧没有 —— 它不属于水位体系。
    let seq: Int?
    let type: String
    let time: Double
    let data: JSONValue
    /// 事件在模型可见面上的动作（顶层 `surfaceOp`）。`nil` 按「追加」处理。
    let surface: JSONValue?

    init(order: Double, seq: Int?, type: String, time: Double, data: JSONValue, surface: JSONValue? = nil) {
        self.order = order
        self.seq = seq
        self.type = type
        self.time = time
        self.data = data
        self.surface = surface
    }

    init(_ event: SessionEvent) {
        self.init(order: Double(event.seq), seq: event.seq,
                  type: event.type, time: event.time, data: event.data, surface: event.surfaceOp)
    }

    /// 这条事件是不是「替换」而不是「追加」—— 压缩点用。
    var isReplacement: Bool { surface?["op"]?.string == "replace" }
}

extension AssemblyEvent {
    /// 事件自带的轮次与步骤号。缺席（或不是非负整数）就是不知道。
    var turn: Int? { Self.coordinate(data["turn"]) }
    var step: Int? { Self.coordinate(data["step"]) }

    /// `turn` 显式为 `null` 表示「这条事件不属于任何一轮」（会话级事实）。
    /// 与「不知道」是两件事：前者不继承上一轮的坐标，后者可以。
    var isSessionScoped: Bool {
        if case .null = data["turn"] { return true }
        return false
    }

    private static func coordinate(_ value: JSONValue?) -> Int? {
        guard let number = value?.int, number >= 0 else { return nil }
        return number
    }
}

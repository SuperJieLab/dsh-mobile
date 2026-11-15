/**
 * 紧凑流的展开 —— 服务端存的不是「一条记录一个 chunk」，而是按块压起来的记录。
 *
 * 真实形状只有四种：
 * - `{type:"chunk", time, chunk}`（块边界、usage、finish 才是这个形状）
 * - `{type:"text-chunks", time0, index, dt:[…], texts:[…]}`
 * - `{type:"reasoning-chunks", …同上}`
 * - `{type:"tool-call-chunks", time0, index, id?, name?, dt:[…], args:[…]}`
 *
 * 把 `texts` 逐条还原成 `text-delta` 并累加 `dt` 才是原来的时间序列。**少这一步的话，
 * 重连基线与失败 attempt 的文字一条也画不出来** —— 记录本身不是 chunk，`chunk["text"]` 取不到。
 */
import Foundation

enum CompactStream {

    struct Record: Equatable {
        let time: Double
        let chunk: JSONValue
    }

    /// 展开成按时间排列的 chunk 序列。认不出的记录跳过（不猜）。
    static func expand(_ stream: [JSONValue]) -> [Record] {
        var records: [Record] = []
        for raw in stream {
            switch raw["type"]?.string {
            case "chunk":
                guard let chunk = raw["chunk"] else { continue }
                records.append(Record(time: raw["time"]?.number ?? 0, chunk: chunk))

            case "text-chunks", "reasoning-chunks":
                let deltaType = raw["type"]?.string == "text-chunks" ? "text-delta" : "reasoning-delta"
                for (index, text) in (raw["texts"]?.array ?? []).enumerated() {
                    guard let value = text.string else { continue }
                    records.append(Record(
                        time: time(at: index, in: raw),
                        chunk: .object([
                            "type": .string(deltaType),
                            "index": .number(Double(raw["index"]?.int ?? 0)),
                            "text": .string(value),
                        ])
                    ))
                }

            case "tool-call-chunks":
                for (index, argument) in (raw["args"]?.array ?? []).enumerated() {
                    guard let value = argument.string else { continue }
                    var chunk: [String: JSONValue] = [
                        "type": .string("tool-call-delta"),
                        "index": .number(Double(raw["index"]?.int ?? 0)),
                        "argumentsDelta": .string(value),
                    ]
                    if let id = raw["id"]?.string { chunk["id"] = .string(id) }
                    if let name = raw["name"]?.string { chunk["name"] = .string(name) }
                    records.append(Record(time: time(at: index, in: raw), chunk: .object(chunk)))
                }

            default:
                continue
            }
        }
        return records
    }

    /// 第 `index` 段的时间 = `time0` + 之前每一段的间隔之和。
    private static func time(at index: Int, in record: JSONValue) -> Double {
        var value = record["time0"]?.number ?? 0
        let gaps = record["dt"]?.array ?? []
        for step in 0..<index {
            guard step < gaps.count else { break }
            value += gaps[step].number ?? 0
        }
        return value
    }
}

/**
 * 任意 JSON 值 —— 载荷里「字段由上游决定」的那部分用它承载。
 */
import Foundation

enum JSONValue: Decodable, Encodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not null, number, bool, string, array or object"
            )
        }
    }

    /// 对称的编码：跟解码一样按实际类型走 —— `JSONValue` 要能在两个方向上
    /// 原样表示任意 JSON（订阅流要往回发帧）。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// 数值。与 `int` 并存而不是取代它：`int` 多一条「非负整数」的约束，
    /// 读游标一类的地方要那一条；时间戳与长度这类「是数就行」的用它。
    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// 取对象里的一个键；拿不到就是 nil。
    subscript(key: String) -> JSONValue? { object?[key] }

    /// 拿一个整数字段；拿不到就是 `nil`。凡要读协议对象里的整数都用它 ——
    /// 非负整数才算数（负数与小数一律 `nil`），因为协议里的整数字段都不接受负值。
    var int: Int? {
        if case .number(let value) = self, value == value.rounded(), value >= 0 { return Int(value) }
        return nil
    }
}

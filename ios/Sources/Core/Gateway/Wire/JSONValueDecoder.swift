/**
 * 把已经解析成 `JSONValue` 的载荷当作解码源 —— 「按流解码」的那座桥。
 *
 * 为什么需要它：`item` 的货物在每条流上形状不同（`baseline` 在 `session/control` 上是
 * 投影表、在 `workspace/follow` 上是组清单），所以连接层不再猜它是哪一种，只把原始值
 * 交出去（`InboundFrame.value`）。各收端拿到的是 `JSONValue`，而它们要的类型都已经写了
 * `Decodable` —— 把值再编回字节交给 `JSONDecoder` 会走一遍「值 → 字节 → 值」，那条路上
 * 整数与缺省都可能被改写。这里直接实现 `Decoder`：树只走一次，类型照旧只声明一遍。
 *
 * 语义对齐 `JSONDecoder`：
 * - 字符串不认数字、数字不认字符串（不做隐式转换）；
 * - `Int` 只从**整数**值来（`3.7` 不是 `3`），且溢出与负数按类型自身范围拒；
 * - `null` 与「键不在」分得开：`decodeNil` 对缺席抛错，`decodeIfPresent` 对缺席给 `nil`。
 */
import Foundation

/// 一棵已解析的 JSON 树 → 任何 `Decodable`。
///
/// 用法与 `JSONDecoder` 同：`T(from: JSONValueDecoder(value))`。
struct JSONValueDecoder: Decoder {

    let value: JSONValue
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: any Any]

    init(_ value: JSONValue,
         codingPath: [any CodingKey] = [],
         userInfo: [CodingUserInfoKey: any Any] = [:]) {
        self.value = value
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw JSONValueDecodingError.mismatch("an object", at: codingPath)
        }
        return KeyedDecodingContainer(KeyedContainer<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let array) = value else {
            throw JSONValueDecodingError.mismatch("an array", at: codingPath)
        }
        return UnkeyedContainer(array: array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueContainer(value: value, codingPath: codingPath)
    }
}

// MARK: - 值的取法（三处容器共用一张）

private enum Scalar {

    static func bool(_ value: JSONValue) -> Bool? {
        if case .bool(let decoded) = value { return decoded }
        return nil
    }

    static func string(_ value: JSONValue) -> String? {
        if case .string(let decoded) = value { return decoded }
        return nil
    }

    static func double(_ value: JSONValue) -> Double? {
        if case .number(let decoded) = value { return decoded }
        return nil
    }

    /// 整数值才认：`3.0` 是 3，`3.7` 不是 3。越界交给 `T(exactly:)` 判 —— 它对负数取无符号
    /// 类型同样给 `nil`，不必在这里再分一次符号。
    static func integer<T: FixedWidthInteger>(_ value: JSONValue, as type: T.Type) -> T? {
        guard case .number(let number) = value, number.isFinite, number == number.rounded() else { return nil }
        return T(exactly: number)
    }
}

private enum JSONValueDecodingError {

    static func mismatch(_ expected: String, at path: [any CodingKey]) -> DecodingError {
        DecodingError.typeMismatch(JSONValue.self, .init(
            codingPath: path,
            debugDescription: "expected \(expected)"
        ))
    }

    static func missing(_ key: any CodingKey, at path: [any CodingKey]) -> DecodingError {
        DecodingError.keyNotFound(key, .init(
            codingPath: path,
            debugDescription: "no value for \"\(key.stringValue)\""
        ))
    }

    static func outOfBounds(_ index: Int, count: Int, at path: [any CodingKey]) -> DecodingError {
        DecodingError.valueNotFound(JSONValue.self, .init(
            codingPath: path,
            debugDescription: "index \(index) is past the end of \(count) values"
        ))
    }
}

/// 数组里的位置也要能进 `codingPath`（错误信息里读得出「第几项坏了」）。
private struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { String(intValue ?? 0) }

    init(_ index: Int) { intValue = index }
    init?(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { intValue = Int(stringValue) }
}

// MARK: - 键值容器

private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

    let object: [String: JSONValue]
    let codingPath: [any CodingKey]

    var allKeys: [Key] { object.keys.compactMap(Key.init(stringValue:)) }

    func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

    private func found(_ key: Key) throws -> JSONValue {
        guard let value = object[key.stringValue] else {
            throw JSONValueDecodingError.missing(key, at: codingPath)
        }
        return value
    }

    private func required<T>(_ key: Key, _ expected: String, _ extract: (JSONValue) -> T?) throws -> T {
        guard let decoded = extract(try found(key)) else {
            throw JSONValueDecodingError.mismatch(expected, at: codingPath + [key])
        }
        return decoded
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        if case .null = try found(key) { return true }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try required(key, "a bool", Scalar.bool) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try required(key, "a string", Scalar.string) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try required(key, "a number", Scalar.double) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try required(key, "a number") { Scalar.double($0).map(Float.init) }
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try required(key, "an integer") { Scalar.integer($0, as: Int.self) } }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try required(key, "an integer") { Scalar.integer($0, as: Int8.self) } }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try required(key, "an integer") { Scalar.integer($0, as: Int16.self) } }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try required(key, "an integer") { Scalar.integer($0, as: Int32.self) } }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try required(key, "an integer") { Scalar.integer($0, as: Int64.self) } }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try required(key, "an integer") { Scalar.integer($0, as: UInt.self) } }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try required(key, "an integer") { Scalar.integer($0, as: UInt8.self) } }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try required(key, "an integer") { Scalar.integer($0, as: UInt16.self) } }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try required(key, "an integer") { Scalar.integer($0, as: UInt32.self) } }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try required(key, "an integer") { Scalar.integer($0, as: UInt64.self) } }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try T(from: JSONValueDecoder(try found(key), codingPath: codingPath + [key]))
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        guard case .object(let object) = try found(key) else {
            throw JSONValueDecodingError.mismatch("an object", at: codingPath + [key])
        }
        return KeyedDecodingContainer(KeyedContainer<NestedKey>(
            object: object, codingPath: codingPath + [key]
        ))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        guard case .array(let array) = try found(key) else {
            throw JSONValueDecodingError.mismatch("an array", at: codingPath + [key])
        }
        return UnkeyedContainer(array: array, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder {
        JSONValueDecoder(.null, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        JSONValueDecoder(try found(key), codingPath: codingPath + [key])
    }
}

// MARK: - 数组容器

private struct UnkeyedContainer: UnkeyedDecodingContainer {

    let array: [JSONValue]
    let codingPath: [any CodingKey]
    var currentIndex = 0

    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }

    private mutating func peek() throws -> JSONValue {
        guard currentIndex < array.count else {
            throw JSONValueDecodingError.outOfBounds(currentIndex, count: array.count, at: codingPath)
        }
        return array[currentIndex]
    }

    private mutating func take() throws -> JSONValue {
        let value = try peek()
        currentIndex += 1
        return value
    }

    private mutating func required<T>(_ expected: String, _ extract: (JSONValue) -> T?) throws -> T {
        let index = currentIndex
        let value = try take()
        guard let decoded = extract(value) else {
            throw JSONValueDecodingError.mismatch(expected, at: codingPath + [IndexKey(index)])
        }
        return decoded
    }

    mutating func decodeNil() throws -> Bool {
        guard case .null = try peek() else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try required("a bool", Scalar.bool) }
    mutating func decode(_ type: String.Type) throws -> String { try required("a string", Scalar.string) }
    mutating func decode(_ type: Double.Type) throws -> Double { try required("a number", Scalar.double) }
    mutating func decode(_ type: Float.Type) throws -> Float { try required("a number") { Scalar.double($0).map(Float.init) } }
    mutating func decode(_ type: Int.Type) throws -> Int { try required("an integer") { Scalar.integer($0, as: Int.self) } }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try required("an integer") { Scalar.integer($0, as: Int8.self) } }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try required("an integer") { Scalar.integer($0, as: Int16.self) } }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try required("an integer") { Scalar.integer($0, as: Int32.self) } }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try required("an integer") { Scalar.integer($0, as: Int64.self) } }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try required("an integer") { Scalar.integer($0, as: UInt.self) } }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try required("an integer") { Scalar.integer($0, as: UInt8.self) } }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try required("an integer") { Scalar.integer($0, as: UInt16.self) } }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try required("an integer") { Scalar.integer($0, as: UInt32.self) } }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try required("an integer") { Scalar.integer($0, as: UInt64.self) } }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let index = currentIndex
        return try T(from: JSONValueDecoder(try take(), codingPath: codingPath + [IndexKey(index)]))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let index = currentIndex
        guard case .object(let object) = try take() else {
            throw JSONValueDecodingError.mismatch("an object", at: codingPath + [IndexKey(index)])
        }
        return KeyedDecodingContainer(KeyedContainer<NestedKey>(
            object: object, codingPath: codingPath + [IndexKey(index)]
        ))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let index = currentIndex
        guard case .array(let array) = try take() else {
            throw JSONValueDecodingError.mismatch("an array", at: codingPath + [IndexKey(index)])
        }
        return UnkeyedContainer(array: array, codingPath: codingPath + [IndexKey(index)])
    }

    mutating func superDecoder() throws -> any Decoder {
        JSONValueDecoder(try take(), codingPath: codingPath)
    }
}

// MARK: - 单值容器

private struct SingleValueContainer: SingleValueDecodingContainer {

    let value: JSONValue
    let codingPath: [any CodingKey]

    private func required<T>(_ expected: String, _ extract: (JSONValue) -> T?) throws -> T {
        guard let decoded = extract(value) else {
            throw JSONValueDecodingError.mismatch(expected, at: codingPath)
        }
        return decoded
    }

    func decodeNil() -> Bool {
        if case .null = value { return true }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool { try required("a bool", Scalar.bool) }
    func decode(_ type: String.Type) throws -> String { try required("a string", Scalar.string) }
    func decode(_ type: Double.Type) throws -> Double { try required("a number", Scalar.double) }
    func decode(_ type: Float.Type) throws -> Float { try required("a number") { Scalar.double($0).map(Float.init) } }
    func decode(_ type: Int.Type) throws -> Int { try required("an integer") { Scalar.integer($0, as: Int.self) } }
    func decode(_ type: Int8.Type) throws -> Int8 { try required("an integer") { Scalar.integer($0, as: Int8.self) } }
    func decode(_ type: Int16.Type) throws -> Int16 { try required("an integer") { Scalar.integer($0, as: Int16.self) } }
    func decode(_ type: Int32.Type) throws -> Int32 { try required("an integer") { Scalar.integer($0, as: Int32.self) } }
    func decode(_ type: Int64.Type) throws -> Int64 { try required("an integer") { Scalar.integer($0, as: Int64.self) } }
    func decode(_ type: UInt.Type) throws -> UInt { try required("an integer") { Scalar.integer($0, as: UInt.self) } }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try required("an integer") { Scalar.integer($0, as: UInt8.self) } }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try required("an integer") { Scalar.integer($0, as: UInt16.self) } }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try required("an integer") { Scalar.integer($0, as: UInt32.self) } }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try required("an integer") { Scalar.integer($0, as: UInt64.self) } }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: JSONValueDecoder(value, codingPath: codingPath))
    }
}

/**
 * `JSONValueDecoder` 的判据 —— 一棵已解析的 JSON 树解成 `Decodable` 时，语义要与
 * `JSONDecoder` 对齐。
 *
 * 它是「按流解货物」的落点：各收端拿到的是 `InboundFrame.value`（通用树），而它们要的
 * 类型都写了 `Decodable`。桥接一旦比 `JSONDecoder` 宽或严，症状是「网关发得对、手机读错」，
 * 而且只在某一种载荷上出现 —— 所以这里逐条钉住四条最容易被写松的规则：
 *
 * - 数字不认字符串、`Int` 只认整数值（`3.7` 不是 `3`）；
 * - 布尔不认字符串与数字；
 * - 缺必填键抛错，缺可选键给 `nil`，显式 `null` 也给 `nil`；
 * - 嵌套（对象里的数组、数组里的对象、字符串键的字典）逐层成立。
 */
import Foundation
import XCTest

@testable import DshMobile

final class JSONValueDecoderTests: XCTestCase {

    private struct Inner: Decodable, Equatable {
        let id: String
        let weight: Double
    }

    private struct Sample: Decodable, Equatable {
        let name: String
        let count: Int
        let ratio: Double
        let flag: Bool
        let optional: String?
        let nested: [Inner]
        let lookup: [String: Int]
        let payload: JSONValue
    }

    /// 与 `InboundFrame` 同一条路：线上字节 → 通用树 → 目标类型。
    private func tree(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func decode(_ text: String) throws -> Sample? {
        try? Sample(from: JSONValueDecoder(tree(text)))
    }

    private let full = """
    {"name":"s-1","count":3,"ratio":1.5,"flag":true,
     "nested":[{"id":"a","weight":0.5},{"id":"b","weight":2}],
     "lookup":{"x":1,"y":2},
     "payload":{"any":["shape",1,null]}}
    """

    func testEveryFieldKindSurvivesTheTree() throws {
        let sample = try XCTUnwrap(decode(full), "整棵树该解得出")

        XCTAssertEqual(sample.name, "s-1")
        XCTAssertEqual(sample.count, 3, "整数从整数值来")
        XCTAssertEqual(sample.ratio, 1.5)
        XCTAssertTrue(sample.flag)
        XCTAssertNil(sample.optional, "缺可选键给 nil，不是空串")

        XCTAssertEqual(sample.nested.map(\.id), ["a", "b"], "数组里的对象逐项解")
        XCTAssertEqual(sample.nested.map(\.weight), [0.5, 2], "整数 2 当 Double 也成立")
        XCTAssertEqual(sample.lookup, ["x": 1, "y": 2], "字符串键的字典逐项解")
        XCTAssertEqual(sample.payload["any"]?.array?[2], .null, "任意形状那一格原样保留（含 null 元素）")
    }

    /// `Int` 只认整数值。写松成 `Int(number)` 会把 `3.7` 悄悄变成 `3` ——
    /// 载荷里并不多见，但 `seq` / `asOfSeq` 一旦被这样截断，水位就错了。
    func testIntegerRefusesFractionsAndStrings() throws {
        XCTAssertNil(try decode(#"{"name":"n","count":3.7,"ratio":1,"flag":true,"nested":[],"lookup":{},"payload":{}}"#),
                     "3.7 不是整数")
        XCTAssertNil(try decode(#"{"name":"n","count":"3","ratio":1,"flag":true,"nested":[],"lookup":{},"payload":{}}"#),
                     "数字不认字符串")
    }

    func testBooleansAreNotCoerced() throws {
        XCTAssertNil(try decode(#"{"name":"n","count":1,"ratio":1,"flag":"true","nested":[],"lookup":{},"payload":{}}"#),
                     "布尔不认字符串")
        XCTAssertNil(try decode(#"{"name":"n","count":1,"ratio":1,"flag":1,"nested":[],"lookup":{},"payload":{}}"#),
                     "布尔不认数字")
    }

    func testMissingRequiredKeyIsAnErrorAndNullOptionalIsNil() throws {
        XCTAssertNil(try decode(#"{"name":"n","ratio":1,"flag":true,"nested":[],"lookup":{},"payload":{}}"#),
                     "缺必填键要抛错，不补默认值")
        let withNull = try decode(#"{"name":"n","count":1,"ratio":1,"flag":true,"optional":null,"nested":[],"lookup":{},"payload":{}}"#)
        XCTAssertNil(withNull?.optional, "显式 null 与缺席同解（可选那一格）")

        // 缺席与 null 在**必填**那一格上都要抛：`decodeNil` 对缺席抛 keyNotFound。
        XCTAssertNil(try decode(#"{"name":null,"count":1,"ratio":1,"flag":true,"nested":[],"lookup":{},"payload":{}}"#),
                     "必填键是 null → 抛错，而不是解成空串")
    }

    func testAnArrayElementThatDoesNotFitFailsTheWholeValue() throws {
        // 坏元素让整份解不出（与 `FailableDecodable` 的「单条跳过」不同 —— 那是它自己包的）。
        XCTAssertNil(try decode(#"{"name":"n","count":1,"ratio":1,"flag":true,"nested":[{"id":"a"}],"lookup":{},"payload":{}}"#),
                     "数组里缺字段的元素让整份失败")
    }

    func testRootMustBeAnObjectForAKeyedType() throws {
        // `init(from:)` 对非对象根**抛** `typeMismatch`：写成 `XCTAssertNil(try …)` 时
        // 抛出的错会直接冒出去，断言本身根本没机会比较。
        XCTAssertThrowsError(try Sample(from: JSONValueDecoder(.array([]))),
                             "根不是对象时该抛错") { error in
            guard case DecodingError.typeMismatch = error else {
                return XCTFail("根不是对象该报 typeMismatch，实际：\(error)")
            }
        }
        XCTAssertThrowsError(try Sample(from: JSONValueDecoder(.null)), "根是 null 时也抛错")
    }
}

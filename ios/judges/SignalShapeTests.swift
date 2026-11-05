/**
 * 阶段变化通知的形状：两层同形，旧名不留。
 *
 * 判据只回答一件事 —— 「以后有人把窄信号写回来、或把旧名加回来，会红吗」。
 * 行为（带的是不是真的旧值、同值发不发）不在这里，在 `MeshStoreTests` 与
 * `WebSocketConnectionTests`；这里守的是**形状**，两者互不替代。
 *
 * 匹配按**标识符边界**：`onPhaseChange` 是 `onPhaseChanged` 的前缀，`contains` 会永远命中 ——
 * 那样这条判据恒红或恒绿，等于没有。
 */
import Foundation
import XCTest

final class SignalShapeTests: XCTestCase {

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ios/tests/
            .deletingLastPathComponent()   // ios/
            .appendingPathComponent("Sources")
    }

    func testPhaseChangeNotificationsAreWideAndHaveNoLegacyName() throws {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil))
        var definitions = 0
        var offenders: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for legacy in ["onPhaseReady", "onPhaseChange"] where containsIdentifier(legacy, in: text) {
                offenders.append("\(url.lastPathComponent): \(legacy)")
            }
            if containsIdentifier("onPhaseChanged", in: text) {
                definitions += text.components(separatedBy: "var onPhaseChanged:").count - 1
            }
        }

        XCTAssertEqual(offenders, [],
                       "旧名还在：\(offenders) —— 窄信号与旧名字都会被接收方读成另一件事")
        XCTAssertEqual(definitions, 2,
                       "阶段变化通知应当两处各一个（组网层与连接层）；"
                       + "少一处说明有人又写了个窄的，多一处说明有人加了第三种形状")
        // 「首参是旧值」这一半不在这里扫：两处消费点（`AppServices` 与 `LongConnection`）
        // 都写成两参闭包，签名改成窄的会直接编译不过 —— 编译器已经在守，再写一条正则
        // 只会随 Swift 语法变化而误报。
    }

    /// 标识符边界匹配：命中处的前后都不能是字母、数字或下划线。
    private func containsIdentifier(_ name: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: name, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let leftBoundary = before.map { !isIdentifierChar($0) } ?? true
            let rightBoundary = after.map { !isIdentifierChar($0) } ?? true
            if leftBoundary && rightBoundary { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private func isIdentifierChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}

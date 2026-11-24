/**
 * `api-session/…` 这类事件 → 列表变化。
 *
 * 翻译住在客户端的 `SessionListEvents`：网关只转发 `api-session/…` 的名字，不做归类 ——
 * 「哪一类事件算列表变化」因此只有这一份表，逐类对齐才守得住。
 */
import XCTest
@testable import DshMobile

final class SessionListEventsTests: XCTestCase {

    private func args(_ items: [JSONValue]) -> JSONValue { .array(items) }

    private func host(_ overrides: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "sessionId": .string("s1"),
            "updatedAt": .number(100),
            "running": .bool(true),
            "blank": .bool(false),
            "agentAvailable": .bool(true),
            "projections": .object(["values": .object(["title": .string("标题")])]),
        ]
        for (key, value) in overrides { object[key] = value }
        return .object(object)
    }

    func testAddedMapsTheWholeRow() {
        let change = SessionListEvents.changeOf(event: "api-session/added", args: args([host()]))
        guard case .added(let row)? = change else { return XCTFail("该落成 added，实际：\(String(describing: change))") }
        XCTAssertEqual(row.id, "s1")
        XCTAssertEqual(row.title, "标题")
        XCTAssertEqual(row.updatedAt, 100)
        XCTAssertTrue(row.running)
        XCTAssertFalse(row.blank)
        XCTAssertTrue(row.agentAvailable)
        XCTAssertNil(row.cwd, "上游不带这一格时字段缺席，不是空串")
    }

    /// `running` / `blank` / `agentAvailable` 在上游都是必填：缺了要**丢这一条**，
    /// 不能补一个 `false` —— 补出来的行看起来完全正常，只是在屏幕上说了错的话。
    ///
    /// 三个字段各测一次：只测一个的话，另两个退回默认值仍然绿。
    func testAnAddedRowWithoutItsRequiredBooleansIsDropped() {
        for key in ["running", "blank", "agentAvailable"] {
            var object = host().object ?? [:]
            object[key] = nil
            XCTAssertNil(
                SessionListEvents.changeOf(event: "api-session/added", args: args([.object(object)])),
                "缺 \(key)：不能补默认值")
        }
        // 正控：三格都在时照常解出来，否则上面三条在「这一支整个坏了」时也绿。
        XCTAssertNotNil(SessionListEvents.changeOf(event: "api-session/added", args: args([host()])))
    }

    func testRemovedStatusActivityMapPositionally() {
        guard case .removed(let id)? = SessionListEvents.changeOf(event: "api-session/removed", args: args([.string("s1")])) else {
            return XCTFail("removed 该带 id")
        }
        XCTAssertEqual(id, "s1")

        guard case .status(let statusId, let running)? = SessionListEvents.changeOf(
            event: "api-session/status", args: args([.string("s1"), .bool(false)])
        ) else { return XCTFail("status 该带 id 与 running") }
        XCTAssertEqual(statusId, "s1")
        XCTAssertFalse(running)

        guard case .activity(let activityId, let at)? = SessionListEvents.changeOf(
            event: "api-session/activity", args: args([.string("s1"), .number(42)])
        ) else { return XCTFail("activity 该带 id 与 updatedAt") }
        XCTAssertEqual(activityId, "s1")
        XCTAssertEqual(at, 42)
    }

    /// 参数畸形一律 `nil` —— 猜一个比丢掉更坏。
    func testMalformedArgumentsAreRejected() {
        XCTAssertNil(SessionListEvents.changeOf(event: "api-session/added", args: .string("nope")))
        XCTAssertNil(SessionListEvents.changeOf(event: "api-session/removed", args: args([])))
        XCTAssertNil(SessionListEvents.changeOf(event: "api-session/removed", args: args([.string("")])))
        XCTAssertNil(SessionListEvents.changeOf(event: "api-session/status", args: args([.string("s1")])), "缺 running")
        XCTAssertNil(SessionListEvents.changeOf(event: "api-session/activity", args: args([.string("s1"), .string("x")])))
        XCTAssertNil(SessionListEvents.changeOf(event: "api-session/unknown", args: args([.string("s1")])))
    }
}

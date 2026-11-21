/**
 * 分派判定：一个 `waterfall` 属于哪个域。
 *
 * 这条判据守的是「分派只有一处」—— 它是 `EventsPendingSink` 两个订阅口的唯一依据，
 * 写错一处就会让某一类挂起项既进不了审批表、也进不了问题表（而两边都不会报错）。
 */
import XCTest

@testable import DshMobile

final class PendingEventRouterTests: XCTestCase {

    private func payload(_ event: String?) -> JSONValue {
        guard let event else { return .object(["eventId": .string("e1")]) }
        return .object(["event": .string(event), "eventId": .string("e1")])
    }

    func testItTellsTheTwoKindsApart() {
        XCTAssertEqual(PendingEventRouter.kind(of: payload("approval/request")), .approval)
        XCTAssertEqual(PendingEventRouter.kind(of: payload("user-questions/request")), .question)
    }

    func testAnUnknownOrMissingEventIsNotGuessed() {
        XCTAssertNil(PendingEventRouter.kind(of: payload("third/thing")),
                     "不认识的类别不猜 —— 猜错会让它落进错误的表，而那张表不会报错")
        XCTAssertNil(PendingEventRouter.kind(of: payload(nil)),
                     "连 event 都没有的载荷同样不归任何域")
    }
}

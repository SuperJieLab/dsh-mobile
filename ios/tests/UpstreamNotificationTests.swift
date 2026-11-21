/**
 * 宿主通知的四条去路 + 不认得的那一支。
 *
 * 它证明的是「四条名字各归自己、其余不猜」—— 而没有这一条时，`SessionDetailState`
 * 的分派要造整个容器才跑得起来，本机与 CI 都不便宜。
 */
import XCTest

@testable import DshMobile

final class UpstreamNotificationTests: XCTestCase {

    func testEachKnownNameHasItsOwnRoute() {
        XCTAssertEqual(UpstreamNotification.route("llm/models-updated"), .models)
        XCTAssertEqual(UpstreamNotification.route("commands/change"), .commands)
        XCTAssertEqual(UpstreamNotification.route("permission-presets/catalog-changed"), .permissions)
        XCTAssertEqual(UpstreamNotification.route("deepseek-account/session-expired"), .accountExpired)
    }

    func testAnUnknownNameIsNotGuessed() {
        XCTAssertEqual(UpstreamNotification.route("something/else"), .unhandled)
        XCTAssertEqual(UpstreamNotification.route(""), .unhandled)
    }

}

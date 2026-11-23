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
        // Host-wide 的流上还有一大票与我们无关的事件：它们必须落 `.unhandled`，
        // 而不是被猜成某一条去路（猜错会让某一屏无端重拉目录）。
        XCTAssertEqual(UpstreamNotification.route("settings/document-created"), .unhandled)
        XCTAssertEqual(UpstreamNotification.route("plugin-manager/changed"), .unhandled)
        XCTAssertEqual(UpstreamNotification.route("schedule/changed"), .unhandled)
    }

    /// 设置文档变了 ⇒ 模型目录可能变了 —— 上游 ModelSelection 面对这两条都刷目录。
    func testASettingsDocumentUpdateRefreshesTheModelCatalog() {
        XCTAssertEqual(UpstreamNotification.route("settings/document-updated"), .models)
    }

}

/**
 * 宿主通知的消费方：转发口与那一句提示。
 *
 * 本文件只验「通知走得通、提示只置一次」。**四条各去哪个部件**由
 * `SessionDetailState` 的闭包决定，而那个容器要造 client / link / store 才能起 ——
 * 本机跑不了，由 CI 的 iOS 车道与真机现象共同守（方案判据表末段已声明）。
 */
import XCTest

@testable import DshMobile

@MainActor
final class UpstreamEventTests: XCTestCase {

    private final class Sink: PendingEventSink {
        var clientId: String? = "c1"
        private(set) var emits: [(String, JSONValue) -> Void] = []

        func onApproval(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onQuestion(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onReady(_ handler: @escaping () -> Void) -> () -> Void { {} }
        func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void {
            emits.append(handler)
            return {}
        }
    }

    private final class NoopAnswerer: QuestionAnswering {
        func answer(eventId: String, answers: [QuestionAnswerItem], clientId: String) async throws {}
    }

    func testNotificationsReachTheStoreForwarder() {
        let sink = Sink()
        let store = QuestionStore(answerer: NoopAnswerer())
        store.attach(sink: sink)

        var seen: [String] = []
        store.watchNotifications { name, _ in seen.append(name) }

        for handler in sink.emits { handler("commands/change", .object([:])) }
        XCTAssertEqual(sink.emits.count, 1, "只注册一次")
        XCTAssertEqual(seen, ["commands/change"], "名字原样送出去 —— 分派由调用方做")
    }

    func testTheLoginExpiredNoticeShowsOnceAndIsDismissable() {
        let flag = LoginExpiredFlag()
        XCTAssertFalse(flag.isShowing)

        flag.note()
        flag.note()
        XCTAssertTrue(flag.isShowing, "重复到达不叠第二条 —— 它是「有事」的标志，不是列表")

        flag.dismiss()
        XCTAssertFalse(flag.isShowing)
    }
}

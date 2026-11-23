/**
 * 宿主通知的 App 级分派（`HostNotifications`）与账号失效标志（`LoginExpiredFlag`）。
 *
 * 这一组守的是「**哪一屏在前台不影响宿主的事实**」：账号过期的提示从前只在会话详情里画，
 * 用户停在列表时什么都看不到 —— 而那时每一次请求都已经被拒了。判据因此从「没有订阅者」
 * 这个状态开始：标志照样置位。
 *
 * 分派规则本身（名字 → 去路）在 `UpstreamNotificationTests`，这里只验「分派之后谁被叫醒」。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class HostNotificationsTests: XCTestCase {

    /// 没有订阅者时账号过期：标志照样置位 —— 列表顶部那条横幅读的就是它。
    func testAnExpiredAccountShowsWithoutAnyScreenWatching() {
        let flag = LoginExpiredFlag()
        let host = HostNotifications(loginExpired: flag)
        XCTAssertFalse(flag.isShowing)

        host.receive("deepseek-account/session-expired")

        XCTAssertTrue(flag.isShowing, "没人订阅时也要置位 —— 提示不该等某一屏打开才出现")
    }

    /// 仍在显示时再来一条不叠加；关掉之后再来一条**会**再出现（那是新的一次失效）。
    ///
    /// 「关掉后同一次失效期内不再出现」这种写法要求一个无法定义的闩：每条 `session-expired`
    /// 都是一次新的失效信号，没有可观测的「失效周期」边界。
    func testRepeatedExpiryWhileShowingDoesNotStackAndComesBackAfterDismiss() {
        let flag = LoginExpiredFlag()
        let host = HostNotifications(loginExpired: flag)

        host.receive("deepseek-account/session-expired")
        host.receive("deepseek-account/session-expired")
        XCTAssertTrue(flag.isShowing, "重复到达仍是一条提示（标志，不是列表）")

        flag.dismiss()
        XCTAssertFalse(flag.isShowing)

        host.receive("deepseek-account/session-expired")
        XCTAssertTrue(flag.isShowing, "关掉之后的新一次失效要再出现")
    }

    /// 三条目录通知叫醒订阅者，并带上各自的去路 —— 详情屏据此刷新三份目录。
    func testCatalogNotificationsReachTheSubscribersWithTheirRoute() {
        let host = HostNotifications(loginExpired: LoginExpiredFlag())
        var seen: [UpstreamNotification.Route] = []
        host.subscribe { seen.append($0) }

        host.receive("llm/models-updated")
        host.receive("commands/change")
        host.receive("permission-presets/catalog-changed")

        XCTAssertEqual(seen, [.models, .commands, .permissions])
    }

    /// 账号失效**不派给目录听众**：它归标志，让每个屏都去处理一遍只会多三处分支。
    func testTheExpiryNoticeIsNotDeliveredToCatalogSubscribers() {
        let host = HostNotifications(loginExpired: LoginExpiredFlag())
        var seen: [UpstreamNotification.Route] = []
        host.subscribe { seen.append($0) }

        host.receive("deepseek-account/session-expired")

        XCTAssertTrue(seen.isEmpty, "账号失效归标志；目录听众不该被它叫醒")
    }

    /// 没人认领的名字不派发（只留痕）—— 猜它属于谁比丢掉更坏。
    func testAnUnknownNotificationReachesNobody() {
        let host = HostNotifications(loginExpired: LoginExpiredFlag())
        var seen: [UpstreamNotification.Route] = []
        host.subscribe { seen.append($0) }

        host.receive("something/else")

        XCTAssertTrue(seen.isEmpty)
    }

    /// 退订之后不再收到：详情每开一次登记一次，不退就永远多一个听众。
    func testUnsubscribingStopsDelivery() {
        let host = HostNotifications(loginExpired: LoginExpiredFlag())
        var count = 0
        let stop = host.subscribe { _ in count += 1 }

        host.receive("commands/change")
        stop()
        host.receive("commands/change")

        XCTAssertEqual(count, 1)
    }
}

/**
 * 票那一层的判据：过期判定只在它里面、并发只换一次、三态不合并。
 *
 * 这一层能脱离网络被断言，正因为它的换票动作是注入的 —— 也是这条判据存在的理由之一：
 * 如果哪天它自己发起请求，这里就搭不起来了。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class TicketKeeperTests: XCTestCase {

    /// 固定的两个时刻：`base` 与 `later`。用常量而不是 `Date()` —— 断言的落点是「过期与否」，
    /// 不该随跑测试的钟漂移。`later` 取 2096 年：写成 1970 的秒数会**立刻过期**，
    /// 那样每条用例都在测「没有票」这一支。
    private static let base = Date(timeIntervalSince1970: 1_000)
    private static let later = Date(timeIntervalSince1970: 4_000_000_000)

    /// 换票脚本：按顺序回放结果，并记录被调了几次。
    private final class Renewals {
        var outcomes: [TicketKeeper.Renewal] = []
        var calls = 0

        func next() -> TicketKeeper.Renewal {
            calls += 1
            guard !outcomes.isEmpty else { return .retryLater }
            return outcomes.removeFirst()
        }
    }

    private func keeper(_ renewals: Renewals) -> TicketKeeper {
        TicketKeeper { _ in renewals.next() }
    }

    /// 有票就立刻给，**一次都不换**。
    func testAValidTicketIsHandedOutWithoutRenewing() async {
        let renewals = Renewals()
        let keeper = TicketKeeper { _ in
            renewals.calls += 1
            return .issued(.init(token: "t1", expiresAt: Self.later))
        }
        _ = await keeper.ticket(deviceToken: "device")
        let second = await keeper.ticket(deviceToken: "device")

        XCTAssertEqual(second, .granted("t1"))
        XCTAssertEqual(renewals.calls, 1, "第二次不该再换 —— 有效期内的票直接用")
    }

    /// **过期判定只有这一处**：`validToken` 是唯一比较 `expiresAt` 的地方，
    /// 过期的票等价于没有票。
    func testAnExpiredTicketIsTreatedAsAbsent() async {
        let keeper = TicketKeeper { _ in
            .issued(.init(token: "short", expiresAt: Self.base))
        }
        _ = await keeper.ticket(deviceToken: "device")

        XCTAssertNil(keeper.validToken(now: Self.base.addingTimeInterval(1)),
                     "过期一秒就不再有效")
        XCTAssertEqual(keeper.validToken(now: Self.base.addingTimeInterval(-1)), "short",
                       "没过期时照常给")
    }

    /// 没有设备凭证 → `.unavailable`，且**一次网络都不发**。
    func testNoDeviceTokenMeansNoRenewalAttempt() async {
        let renewals = Renewals()
        let outcome = await keeper(renewals).ticket(deviceToken: nil)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(renewals.calls, 0, "未配对本就不该发请求")
    }

    /// 并发要票只换一次 —— 第二方搭第一方那一趟。
    func testConcurrentAsksShareOneRenewal() async {
        let renewals = Renewals()
        renewals.outcomes = [.issued(.init(token: "only", expiresAt: Self.later))]
        let keeper = keeper(renewals)

        async let a = keeper.ticket(deviceToken: "device")
        async let b = keeper.ticket(deviceToken: "device")
        async let c = keeper.ticket(deviceToken: "device")
        let answers = await [a, b, c]

        XCTAssertEqual(answers, [.granted("only"), .granted("only"), .granted("only")])
        // 三个并发调用：第一方换，另外两方搭车。判据给上限而非精确值 ——
        // 调度顺序决定谁先到，但无论谁先到都只能有一次换票。
        XCTAssertLessThanOrEqual(renewals.calls, 1, "并发要票只该换一次")
    }

    /// **被服务端否认过的票不能留着**：`.unavailable` 之后 `validToken` 必须是 nil，
    /// 否则下一个请求会拿着同一枚死票出门。
    func testARefusedRelationshipClearsTheHeldTicket() async {
        let renewals = Renewals()
        renewals.outcomes = [
            .issued(.init(token: "doomed", expiresAt: Self.later)),
            .unavailable,
        ]
        let keeper = keeper(renewals)

        _ = await keeper.ticket(deviceToken: "device")
        XCTAssertEqual(keeper.validToken(), "doomed", "先拿到一张还在有效期内的票")

        // 服务端刚说了 401：本地的票看着还有效，但已经被否认。
        let second = await keeper.renewAnyway(deviceToken: "device")
        XCTAssertEqual(second, .unavailable)
        XCTAssertNil(keeper.validToken(), "被否认过的票要清掉，不能继续当有效票递出去")
    }

    /// `.retryLater` **不清**手上的票 —— 网络抖动一下不该等于丢票。
    func testATransientFailureKeepsTheHeldTicket() async {
        let renewals = Renewals()
        renewals.outcomes = [
            .issued(.init(token: "still-good", expiresAt: Self.later)),
            .retryLater,
        ]
        let keeper = keeper(renewals)

        _ = await keeper.ticket(deviceToken: "device")
        _ = await keeper.renewAnyway(deviceToken: "device")

        XCTAssertEqual(keeper.validToken(), "still-good",
                       "暂时换不到，手里那张仍可能有效 —— 不能因为一次网络失败就清掉")
    }
}

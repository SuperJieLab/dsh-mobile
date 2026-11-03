/**
 * 列表底部那条状态带的显示值：哪种处境出哪一条，以及「哪几种处境整条不出现」。
 *
 * 这条带子存在的理由只有一个 —— 常态别占地方。所以判据的第一条就是「直连时没有它」：
 * 少了那一条，把 `make` 改成永远返回一条「直连」也能让其余几条全绿，而屏幕上会多出
 * 一条永远在说「一切正常」的横条。
 *
 * 期望值一律手写：从实现推出来的期望等于没测。
 */
import Foundation
import XCTest

@testable import DshMobile

final class ConnectionStatusBarTests: XCTestCase {

    /// 常态整条不出现 —— 这是这一屏被改的理由，也是这条判据的全部意义。
    func testDirectConnectionShowsNothing() {
        XCTAssertNil(ConnectionStatusBarModel.make(carrier: .direct, failure: nil),
                     "直连是常态：多一条常驻的「一切正常」只是在替屏幕占地方")
    }

    /// 路径还不可知时也不出现 —— 组网在起的过程中列表顶上另有话说。
    func testUnknownPathShowsNothing() {
        XCTAssertNil(ConnectionStatusBarModel.make(carrier: nil, failure: nil))
    }

    /// 中继要出现，但**不给动作**：点它没有事会发生，那就是把按钮做成装饰。
    func testRelayIsAnnouncedWithoutAnAction() throws {
        let model = try XCTUnwrap(ConnectionStatusBarModel.make(carrier: .relay, failure: nil))
        XCTAssertEqual(model.text, "中继 · 较慢", "文案要带上「为什么慢」，否则「中继」两个字对用户没有意义")
        XCTAssertEqual(model.systemImage, "personalhotspot")
        XCTAssertFalse(model.canRetry, "中继只是告知，不是故障")
    }

    /// 断连要出现，而且可点 —— 它取代的那个徽章正是「不能点」被诟病的。
    func testFailureIsRetryable() throws {
        let model = try XCTUnwrap(ConnectionStatusBarModel.make(carrier: .direct, failure: "超时"))
        XCTAssertEqual(model.text, "已断开 · 重连中")
        XCTAssertEqual(model.systemImage, "wifi.slash")
        XCTAssertTrue(model.canRetry)
    }

    /// 两者同时成立时说的是断连：那一刻路径既不可知也不重要。
    func testFailureWinsOverRelay() throws {
        let model = try XCTUnwrap(ConnectionStatusBarModel.make(carrier: .relay, failure: "超时"))
        XCTAssertTrue(model.canRetry, "失败时那条必须能点，哪怕同时还在中继上")
        XCTAssertEqual(model.text, "已断开 · 重连中")
    }

    /// 两条文案互不相同：抄错一格（断连那条写成了中继那句）时，上面每条各自仍然绿。
    func testTheTwoLinesDoNotCollide() throws {
        let relay = try XCTUnwrap(ConnectionStatusBarModel.make(carrier: .relay, failure: nil))
        let offline = try XCTUnwrap(ConnectionStatusBarModel.make(carrier: nil, failure: "超时"))
        XCTAssertNotEqual(relay.text, offline.text)
    }
}

/**
 * 页脚地址那一条的断言 —— 它在没有界面、没有端点实例的条件下跑。
 *
 * 三条各挡一种猜法：`nil` 必须说「未激活」而不是空串（空串会让页脚留一个孤零零的分隔符）；
 * 有值必须原样（不做美化，用户要拿它对照 Mac 侧的日志）；尾斜杠不许被吃掉（`URL.absoluteString`
 * 会保留它，这里守的是「别自己重拼」）。
 */
import Foundation
import XCTest

@testable import DshMobile

final class GatewayAddressTests: XCTestCase {

    func testNilSaysInactive() {
        XCTAssertEqual(gatewayAddressLine(nil), "未激活")
    }

    func testValueIsShownVerbatim() {
        let url = URL(string: "http://100.64.0.7:8787")!
        XCTAssertEqual(gatewayAddressLine(url), "http://100.64.0.7:8787")
    }

    func testTrailingSlashSurvives() {
        let url = URL(string: "http://100.64.0.7:8787/")!
        XCTAssertEqual(gatewayAddressLine(url), "http://100.64.0.7:8787/")
    }
}

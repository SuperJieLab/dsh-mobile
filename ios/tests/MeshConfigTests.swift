/**
 * 组网配置的读盘三态：从没配过 / 存坏了 / 读到了。
 *
 * 三态必须分开，因为它们的后果不同：`missing` 是干净首启，`damaged` 要引导重填而不是
 * 查证书，混成一件会让用户按错误的提示去查另一样东西。
 *
 * 用独立的 UserDefaults 域，不碰 `.standard` —— 测试不该读写真实设备的配置。
 */
import Foundation
import XCTest

@testable import DshMobile

final class MeshConfigTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MeshConfigTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 「配置是否完整」这条规则本身：控制面要 `https`，网关地址只需是个 URL。
    ///
    /// 规则住在 `MeshConfig`，断言就跟它住一起 —— 它不属于任何一屏。
    func testCompleteness() {
        XCTAssertTrue(MeshConfig(controlURLString: "https://a:8443",
                                 gatewayURLString: "http://b:3081").isComplete)
        XCTAssertFalse(MeshConfig(controlURLString: "http://a:8443",
                                  gatewayURLString: "http://b:3081").isComplete,
                       "明文控制面不算完整")
        XCTAssertFalse(MeshConfig(controlURLString: "",
                                  gatewayURLString: "http://b:3081").isComplete,
                       "还没配过（控制面为空）不算完整")
        XCTAssertFalse(MeshConfig(controlURLString: "https://a:8443",
                                  gatewayURLString: "").isComplete,
                       "网关地址为空不算完整")
    }

    /// 从没存过 ⇒ `missing`，不是 `damaged`。
    func testMissingWhenNeverSaved() {
        XCTAssertEqual(MeshConfig.read(defaults), .missing, "空域应当读成「从没配过」")
    }

    /// 存过但解不出来 ⇒ `damaged`，且 `load` 仍给一个可用的形状（回落不崩）。
    ///
    /// 键名不写死：先存一次，再把存进去的那个键改成非法内容 —— 否则改键名之后这条断言
    /// 会静默测不到东西。
    func testDamagedWhenStoredBytesCannotBeDecoded() {
        let config = MeshConfig(controlURLString: "https://example:8443",
                                gatewayURLString: MeshConfig.gatewayDefault)
        config.save(defaults)

        let written = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("mesh.") }
        XCTAssertEqual(written.count, 1, "配置应当只写一个键，实际：\(written)")
        defaults.set("not json", forKey: written[0])

        XCTAssertEqual(MeshConfig.read(defaults), .damaged, "解不出来必须报 damaged")
        XCTAssertFalse(MeshConfig.load(defaults).isComplete, "损坏时给的是未配置的形状")
    }

    /// 存进去再读出来，值一致。
    func testRoundTrip() {
        let config = MeshConfig(controlURLString: "https://example:8443",
                                gatewayURLString: "http://100.64.0.1:3081")
        config.save(defaults)
        XCTAssertEqual(MeshConfig.read(defaults), .ok(config), "读回的值应与存进去的一致")
    }
}

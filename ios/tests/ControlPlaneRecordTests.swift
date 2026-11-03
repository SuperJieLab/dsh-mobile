/**
 * `ControlPlaneRecord` 的判据 —— 启动时「这份身份是不是这一家控制面的」。
 *
 * 每条都用一个独立的 UserDefaults 域：真域是 App 自己的，测试写进去会污染下一次启动。
 */
import Foundation
import XCTest

@testable import DshMobile

final class ControlPlaneRecordTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "ControlPlaneRecordTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    /// 没记录过 = 匹配。**这是升级路径**：老版本没有这一格，而它的状态目录是有效的 ——
    /// 判成不匹配就会把一次升级变成一次掉线 + 重新注册。
    func testNoRecordMeansMatch() {
        let official = URL(string: "https://controlplane.tailscale.com")!
        XCTAssertTrue(ControlPlaneRecord.matches(official, defaults: defaults),
                      "从没记过时不该判成换了控制面")
    }

    /// 记的是哪一家，问的就是哪一家 → 匹配（重开不重注册）。
    func testSameControlPlaneMatches() {
        let official = URL(string: "https://controlplane.tailscale.com")!
        ControlPlaneRecord.save(official, defaults: defaults)
        XCTAssertTrue(ControlPlaneRecord.matches(official, defaults: defaults))
    }

    /// 记的是 A，现在配的是 B → 不匹配。**这条就是 C52 的判据本体**：
    /// 少了它，切控制面之后状态机照样说「已入网」，而目录里躺的是 A 的身份。
    func testDifferentControlPlaneDoesNotMatch() {
        ControlPlaneRecord.save(URL(string: "https://headscale.example:8443")!, defaults: defaults)
        XCTAssertFalse(ControlPlaneRecord.matches(URL(string: "https://controlplane.tailscale.com")!,
                                                  defaults: defaults),
                       "换了控制面必须判成不匹配")
    }

    /// 尾斜杠不是差别 —— `https://x:8443` 与 `https://x:8443/` 是同一个控制面。
    /// 只归一这一项：端口、路径、大小写都有意义，多归一样就会把「真的换了」判成「没换」。
    func testTrailingSlashIsNotADifference() {
        ControlPlaneRecord.save(URL(string: "https://headscale.example:8443")!, defaults: defaults)
        XCTAssertTrue(ControlPlaneRecord.matches(URL(string: "https://headscale.example:8443/")!,
                                                 defaults: defaults))
        XCTAssertFalse(ControlPlaneRecord.matches(URL(string: "https://headscale.example:8444")!,
                                                  defaults: defaults),
                       "端口不同是两家")
    }

    /// 地址解不出来时不记 —— 记一个错的值会让下一次启动白清一遍状态目录。
    func testSavingAnUnusableAddressKeepsTheOldRecord() {
        let official = URL(string: "https://controlplane.tailscale.com")!
        ControlPlaneRecord.save(official, defaults: defaults)
        ControlPlaneRecord.save(nil, defaults: defaults)
        XCTAssertTrue(ControlPlaneRecord.matches(official, defaults: defaults),
                      "存不进的值不该覆盖已经记对的那一个")
    }
}

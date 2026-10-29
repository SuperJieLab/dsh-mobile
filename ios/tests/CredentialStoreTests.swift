/**
 * 设备凭证的变更通知。
 *
 * 它守的是一条**信号**，不是凭证本身：凭证的读写早就有断言（`SecretFile` 与各处调用）。
 * 缺的是「刚变过」这个事件 —— 编排层靠它拉起 / 收起连接，而它以前是靠 UI 的
 * `.task(id: hasDeviceToken)` 顺带完成的。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class CredentialStoreTests: XCTestCase {

    /// 每个用例用独立的内存存储 —— 不碰 App 真正的凭证文件。
    private func store(initial: String? = nil) -> (CredentialStore, () -> String?) {
        var current = initial
        let storage = CredentialStore.Storage(
            read: { current },
            write: { current = $0 },
            delete: { current = nil }
        )
        return (CredentialStore(storage: storage), { current })
    }

    /// 存与删各通知一次 —— 编排层靠它决定拉起还是收起连接。
    func testIdentityChangeNotifiesOnceEachWay() {
        let (credentials, _) = store()
        var notices = 0
        credentials.onIdentityChanged = { notices += 1 }

        credentials.saveDeviceToken("device-token-abc")
        XCTAssertEqual(notices, 1, "存了要通知")

        credentials.deleteDeviceToken()
        XCTAssertEqual(notices, 2, "删了要通知")
    }

    /// 撤销是幂等的：没有凭证时再删一次不通知。
    ///
    /// 为什么值得一条：`deleteDeviceToken` 在「换票 401」与「用户主动解绑」两处都会被调，
    /// 重复通知会让编排层白重走一遍「无身份」那几步 —— 症状是日志里多出一串无害但
    /// 误导的编排记录，排障时会以为是两次撤销。
    func testDeletingWithoutATokenDoesNotNotify() {
        let (credentials, _) = store()
        var notices = 0
        credentials.onIdentityChanged = { notices += 1 }

        credentials.deleteDeviceToken()
        XCTAssertEqual(notices, 0, "本来就没有，删它不算变化")
    }

    /// 正控：通知真的来自存储变化，不是无条件触发。
    func testTheNoticeComesWithTheStoreActuallyChanging() {
        let (credentials, current) = store()
        var seen: [Bool] = []
        credentials.onIdentityChanged = { [weak credentials] in
            seen.append(credentials?.hasDeviceToken ?? false)
        }

        credentials.saveDeviceToken("device-token-abc")
        XCTAssertEqual(current(), "device-token-abc", "落盘了")
        XCTAssertEqual(seen, [true], "通知时读到的已经是「有身份」")

        credentials.deleteDeviceToken()
        XCTAssertNil(current(), "删了")
        XCTAssertEqual(seen, [true, false], "通知时读到的已经是「无身份」")
    }
}

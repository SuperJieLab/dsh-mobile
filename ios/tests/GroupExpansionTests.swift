/**
 * 分组的展开状态：默认折、切换、失效清理、存取。
 *
 * 纯值与一个 `UserDefaults` 键 —— 不建视图、不连网络。这张表的全部内容是「哪些组被点开过」，
 * 它**不回答该不该展开**：没有「新建后自动展开」这条规则（折叠的组上没有「+」，所以那个
 * 状态不会出现），这一层只管记住用户点过什么。
 */
import Foundation
import XCTest

@testable import DshMobile

final class GroupExpansionTests: XCTestCase {

    /// 一个只属于本用例的 suite —— 用 `.standard` 会让测试之间互相污染，也会污染真机偏好。
    private func isolatedDefaults(_ label: String = #function) -> UserDefaults {
        let name = "GroupExpansionTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// 默认折叠：没人点过的时候一个组都不展开。
    func testNothingIsExpandedUntilToggled() {
        let expansion = GroupExpansion()

        XCTAssertFalse(expansion.isExpanded("w-a"), "从未点开过的组必须是折的 —— 这是与 Web UI 同一个默认")
        XCTAssertFalse(expansion.isExpanded(SessionGrouping.ungroupedKey), "未分组也是组，同一条规则")
    }

    /// 同一个组切两次回到原样。
    func testTogglingTwiceReturnsToCollapsed() {
        var expansion = GroupExpansion()

        expansion.toggle("w-a")
        XCTAssertTrue(expansion.isExpanded("w-a"))

        expansion.toggle("w-a")
        XCTAssertFalse(expansion.isExpanded("w-a"), "开关是对合 —— 不是「只会展开」")
    }

    /// 切一个组不动别的组。
    func testTogglingOneGroupLeavesTheOthersAlone() {
        var expansion = GroupExpansion()
        expansion.toggle("w-a")

        expansion.toggle("w-b")

        XCTAssertTrue(expansion.isExpanded("w-a"), "切 B 不该把 A 收起来 —— 那是两个独立的开关")
        XCTAssertTrue(expansion.isExpanded("w-b"))
    }

    /// 已不存在的组，它的记录在求交时被丢掉。
    func testRetainingDropsGroupsThatNoLongerExist() {
        var expansion = GroupExpansion(expanded: ["w-gone", "w-a", SessionGrouping.ungroupedKey])

        expansion.retain(among: ["w-a", SessionGrouping.ungroupedKey])

        XCTAssertFalse(expansion.isExpanded("w-gone"),
                       "在 Web UI 里被删掉的工作空间，记录必须跟着走 —— 否则它永远留在本机偏好里，没有东西会去清")
        XCTAssertTrue(expansion.isExpanded("w-a"))
        XCTAssertTrue(expansion.isExpanded(SessionGrouping.ungroupedKey),
                      "未分组是普通的组：它在清单里就保留，不搞特殊")
    }

    /// 存一轮再取，集合相等。
    func testSavingAndLoadingRoundTrips() {
        let defaults = isolatedDefaults()
        var expansion = GroupExpansion()
        expansion.toggle("w-a")
        expansion.toggle("w-b")
        expansion.toggle("w-a")     // 收起一个，只剩 w-b

        expansion.save(to: defaults)
        let reloaded = GroupExpansion.load(from: defaults)

        XCTAssertEqual(reloaded, expansion, "重启之后要还是那一份")
        XCTAssertTrue(reloaded.isExpanded("w-b"))
        XCTAssertFalse(reloaded.isExpanded("w-a"))
    }

    /// 没存过和存坏了都退化为「全折叠」，不崩。
    func testAMissingOrDamagedRecordFallsBackToCollapsed() {
        let missing = isolatedDefaults()
        XCTAssertEqual(GroupExpansion.load(from: missing), GroupExpansion(),
                       "没存过 = 默认")

        let damaged = isolatedDefaults()
        damaged.set([1, 2, 3], forKey: "sessionlist.expandedGroups.v1")
        XCTAssertEqual(GroupExpansion.load(from: damaged), GroupExpansion(),
                       "键在但读不成字符串数组时按默认处理 —— 它不影响正确性，不值得为它做三态")
    }
}

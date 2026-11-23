/**
 * 组清单 → 归属表（`SessionOwners`）。
 *
 * 归属只有这一处判据：组流给的 `sessionIds`。这条判据守两件事 —— 一个会话只落一个组
 * （重叠时后一个胜），以及**不按目录路径猜**（路径根本不在客户端声明里，想猜也拿不到）。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionOwnersTests: XCTestCase {

    private func workspace(_ id: String, sessions: [String]) -> WorkspaceView {
        WorkspaceView(workspaceId: id, title: id, sessionIds: sessions)
    }

    func testEverySessionOfEveryGroupIsMapped() {
        let owners = SessionOwners.of([
            workspace("w-1", sessions: ["s-1", "s-2"]),
            workspace("w-2", sessions: ["s-3"]),
            workspace("w-3", sessions: []),
        ])

        XCTAssertEqual(owners, ["s-1": "w-1", "s-2": "w-1", "s-3": "w-2"],
                       "空组不贡献任何归属 —— 它的组仍然出现在分组里，那是另一件事")
    }

    func testAnEmptyListYieldsAnEmptyMap() {
        XCTAssertTrue(SessionOwners.of([]).isEmpty)
    }

    /// 同一个会话出现在两个组里：后一个胜。
    ///
    /// 上游的成员表本身不该重叠（一个会话只属于一个工作空间）；出现重叠说明两边的事实
    /// 不一致。此时「最后读到的那一份」与渲染时「按组清单顺序画」同向 —— 至少不会让一个
    /// 会话同时出现在两处。
    func testOverlappingMembershipResolvesToTheLastGroup() {
        let owners = SessionOwners.of([
            workspace("w-1", sessions: ["s-1"]),
            workspace("w-2", sessions: ["s-1"]),
        ])

        XCTAssertEqual(owners, ["s-1": "w-2"])
    }
}

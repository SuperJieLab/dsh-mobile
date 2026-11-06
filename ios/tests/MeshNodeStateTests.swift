/**
 * TailnetNodeState 迁移表逐格断言。状态与事件定义见
 * Sources/Core/MeshNetwork/TailnetNodeState.swift；迁移表以该文件里的 `switch` 为唯一源，
 * 加一个状态时编译器会点出所有要看它的地方。
 *
 * 这里**没有「有没有票」这一维**：票不落盘，只在提交那一次参与，注册成功即丢弃。
 */
import Foundation
import XCTest

@testable import DshMobile

final class MeshNodeStateTests: XCTestCase {

    func testLaunchOnlyNeedsIdentity() {
        // 身份在、且属于这一家：先去起，起不起来由上游状态说话。
        XCTAssertEqual(TailnetNodeState.handle(.launch(identityPresent: true, controlPlaneMatches: true)),
                       .running, "NS1 有身份且控制面未变 → running（随后不带票去连）")
        // 换了控制面：目录里那份身份属于上一家，拿它连新控制面会「连上但通不了」。
        XCTAssertEqual(TailnetNodeState.handle(.launch(identityPresent: true, controlPlaneMatches: false)),
                       .noIdentity, "NS2 身份是别家的 → noIdentity（旧身份一文不值）")
        XCTAssertEqual(TailnetNodeState.handle(.launch(identityPresent: false, controlPlaneMatches: true)),
                       .noIdentity, "NS3 没有身份 → noIdentity")
        XCTAssertEqual(TailnetNodeState.handle(.launch(identityPresent: false, controlPlaneMatches: false)),
                       .noIdentity, "NS4 没有身份且换了控制面 → noIdentity")
    }

    func testSubmittingATicketStartsRegistration() {
        XCTAssertEqual(TailnetNodeState.handle(.keySubmitted, from: .noIdentity), .registering,
                       "NS5 没有身份时用户贴票 → registering")
        XCTAssertEqual(TailnetNodeState.handle(.keySubmitted, from: .failed(.unreachable)), .registering,
                       "NS6 failed 后重贴票同样走 registering（统一入口）")
        XCTAssertEqual(TailnetNodeState.handle(.keySubmitted, from: .failed(.needsAuthKey)), .registering,
                       "NS7 「需要重新接入」后贴票 → registering")
    }

    func testEveryFailureReasonIsDistinct() {
        for failure in [TailnetNodeFailure.badKey, .needsAuthKey, .pendingApproval, .unreachable] {
            XCTAssertEqual(TailnetNodeState.handle(.registrationFailed(failure), from: .registering),
                           .failed(failure), "NS8 四种失败都要原样落库：\(failure)")
        }
        XCTAssertEqual(TailnetNodeState.handle(.registrationSucceeded, from: .registering), .running,
                       "NS9 注册成功 → running")
    }

    func testRetryNeedsIdentityOrTicket() {
        XCTAssertEqual(TailnetNodeState.handle(.retry(identityPresent: true, ticketPresent: false),
                                              from: .failed(.unreachable)),
                       .registering, "NS10 有身份就能重试（不带票）")
        XCTAssertEqual(TailnetNodeState.handle(.retry(identityPresent: false, ticketPresent: true),
                                              from: .failed(.unreachable)),
                       .registering, "NS11 手里还留着票也能重试（首次接入失败那一路）")
        XCTAssertEqual(TailnetNodeState.handle(.retry(identityPresent: false, ticketPresent: false),
                                              from: .failed(.unreachable)),
                       .noIdentity, "NS12 身份和票都没有 → noIdentity，重试没有意义")
        XCTAssertEqual(TailnetNodeState.handle(.retry(identityPresent: false, ticketPresent: false),
                                              from: .failed(.needsAuthKey)),
                       .noIdentity, "NS13 「需要重新接入」再点重试 → 仍是 noIdentity")
    }

    func testRunningStaysSteady() {
        XCTAssertEqual(TailnetNodeState.handle(.appBackgrounded, from: .running), .running,
                       "NS14 进后台不迁移：挂起由 tsnet 复活 + 回前台重连接力")
        XCTAssertEqual(TailnetNodeState.handle(.nodeUnreachable, from: .running), .failed(.unreachable),
                       "NS15 running 中节点失联 → failed(unreachable)")
        XCTAssertEqual(TailnetNodeState.handle(.registrationSucceeded, from: .running), .running,
                       "NS16 前台复活再报成功 → 仍 running（幂等）")
    }

    func testSupersedeLeavesRunningAndFailed() {
        XCTAssertEqual(TailnetNodeState.handle(.superseded, from: .running), .registering,
                       "NS17 running 被取代 → registering（否则 route 仍指向已关闭的节点）")
        XCTAssertEqual(TailnetNodeState.handle(.superseded, from: .failed(.badKey)), .registering,
                       "NS18 failed 被取代 → registering")
        XCTAssertEqual(TailnetNodeState.handle(.superseded, from: .failed(.needsAuthKey)), .registering,
                       "NS19 新一态也必须被这条 pattern 覆盖（否则失败后换代卡死）")
    }
}

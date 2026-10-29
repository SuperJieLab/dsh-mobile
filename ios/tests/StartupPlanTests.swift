/**
 * 启动计划的三条规则。
 *
 * 这一组断言的价值在于**它们不需要构造任何对象**：计划是纯函数，`MeshConfig` 是值类型。
 * 在此之前「启动该做什么、按什么顺序」长在四个 SwiftUI 装饰器里，要跑起界面才碰得到。
 *
 * 期望值一律手写 —— 从实现推出来的期望等于没测。
 */
import Foundation
import XCTest

@testable import DshMobile

final class StartupPlanTests: XCTestCase {

    private let config = MeshConfig(controlURLString: "https://203.0.113.10:8443",
                                    gatewayURLString: "http://100.64.0.1:3081")

    /// 未配对：**仍挂审批**，但**不去连**。
    ///
    /// 两个方向都会坏：
    /// - 不挂审批 ⇒ 刚配对完就来的第一张卡丢掉（事件不重放）；
    /// - 去连了 ⇒ 无票可换，连接层把「无票」当终态收成 `.idle`，
    ///   日志里留一条误导的握手尝试。
    func testWithoutIdentityAttachesApprovalsButStaysOffline() {
        let steps = StartupPlan.steps(hasIdentity: false, config: .ok(config))

        XCTAssertTrue(steps.contains(.attachApprovals), "审批是 App 级的，与身份无关")
        XCTAssertFalse(steps.contains(.activateLink), "没配对该先配对，不连")
        XCTAssertFalse(steps.contains(.attachEventStream), "没有连接时登记流没有意义")
    }

    /// 有身份：激活必须早于登记事件流。
    ///
    /// `attachEventStream` 会开流，而开流经 `ensureConnected`，那个方法第一行是
    /// 「不 active 就直接返回」。顺序反了的症状是「配对成功但列表永远不动」，
    /// 且不编译失败 —— 只有这条断言抓得住。
    func testWithIdentityActivatesTheLinkBeforeAttachingTheEventStream() {
        let steps = StartupPlan.steps(hasIdentity: true, config: .ok(config))
        guard let activate = steps.firstIndex(of: .activateLink),
              let attach = steps.firstIndex(of: .attachEventStream) else {
            XCTFail("两个动作都在：\(steps)")
            return
        }
        XCTAssertLessThan(activate, attach, "activate 必须在前：\(steps)")
        XCTAssertEqual(steps.first, .attachApprovals, "审批仍是最先那一步")
    }

    /// 读盘的三种结果各走各的：`damaged` 不许交给节点。
    ///
    /// 把它并进 `missing`（当成干净首启）的症状这里再记一次：空配置起节点 →
    /// 节点层报「不可达」→ 界面引导去查 VPS 与证书，而用户真正该做的是重填地址。
    func testEveryConfigOutcomeMapsToItsOwnStep() {
        let okSteps = StartupPlan.steps(hasIdentity: true, config: .ok(config))
        XCTAssertTrue(okSteps.contains(.launchMesh(config)), "读到了就照它起")

        let missingSteps = StartupPlan.steps(hasIdentity: true, config: .missing)
        XCTAssertTrue(missingSteps.contains(.launchMesh(.unconfigured)),
                      "干净首启：起一个未配置的节点，让状态机给出 needsSetup")

        let damagedSteps = StartupPlan.steps(hasIdentity: true, config: .damaged)
        XCTAssertTrue(damagedSteps.contains(.reportDamaged), "坏了要如实说")
        XCTAssertFalse(damagedSteps.contains { if case .launchMesh = $0 { return true }
                                               else { return false } },
                       "坏配置不许交给节点：\(damagedSteps)")
    }

    /// 身份从无到有只补连接那两步 —— 不重挂审批、不重起组网。
    ///
    /// 重起组网的症状最重：`launchMesh` 会重启 tsnet，把活着的连接与路径展示一起清掉。
    func testIdentityBecameAvailableOnlyCarriesTheConnectionSteps() {
        XCTAssertEqual(StartupPlan.identityBecameAvailable, [.activateLink, .attachEventStream])
    }
}

/**
 * 启动编排的**计划** —— 一个纯函数：给定「有没有身份」与「读盘的三种结果」，
 * 回答该做哪些动作、按什么顺序做。
 *
 * 它只产出一个步骤列表，不执行、不认识任何服务。于是「启动该做什么」这件事终于能被
 * 穷举断言 —— 在此之前它散在四个 `.task` / `.onChange` 装饰器里，要跑 SwiftUI 才碰得到。
 *
 * **顺序是契约的一部分**：`activateLink` 必须早于 `attachEventStream` —— 后者开流时会
 * 调 `ensureConnected`，而那个方法的第一行是「不 active 就直接返回」。顺序反了的症状是
 * 「配对成功但列表永远不动」，且不编译失败。
 */
import Foundation

/// 启动时的一件事。取值就是动作本身，不含参数 —— 参数由执行方从服务上取，
/// 让计划与「服务的形状」解耦（换一个签名不会牵动这里）。
enum StartupStep: Equatable {
    /// 挂审批的事件听众。**与身份无关**：停在列表页时它也要收；而「刚配对完就来的
    /// 第一张卡」不能在挂上之前丢掉。
    case attachApprovals
    /// 要一条连接。它的闸只让第一次通过，重复无害。
    case activateLink
    /// 登记事件流。必须在 `activateLink` 之后。
    case attachEventStream
    /// 起组网（内部自己有 15s × 3 重试）。
    case launchMesh(MeshConfig)
    /// 配置存过但读不出来：不起节点，如实说「要重填」。
    case reportDamaged
}

enum StartupPlan {

    /// 启动该走的步骤。
    ///
    /// - Parameters:
    ///   - hasIdentity: 此刻有没有设备凭证。
    ///   - config: 读盘的三种结果（`missing` / `damaged` / `ok`）。
    ///
    /// 三条规则写在这里，各自对着一类会静默出错的处境：
    /// 1. **审批听众恒挂**（理由见 `StartupStep.attachApprovals`）。
    /// 2. **无身份不激活连接**：无票换，连上也白连；连接层会把「无票」当终态收成 `.idle`，
    ///    所以连了也没用，反而在日志里留下一条误导的握手尝试。
    /// 3. **`damaged` 不交给节点**：`launchMesh` 的入参只有「完整配置」与「未配置」两种，
    ///    而 `damaged` 走 `reportDamaged` —— 把坏配置当空配置起节点会报「不可达」，
    ///    用户按那句提示去查 VPS 与证书，而归因从一开始就错了。
    static func steps(hasIdentity: Bool, config: MeshConfig.ReadOutcome) -> [StartupStep] {
        var steps: [StartupStep] = [.attachApprovals]

        if hasIdentity {
            steps.append(.activateLink)
            steps.append(.attachEventStream)
        }
        switch config {
        case .ok(let config):
            steps.append(.launchMesh(config))
        case .missing:
            // 干净首启：起一个「未配置」的节点，让状态机给出 `needsSetup`，
            // 界面据此引导去设置页填地址。
            steps.append(.launchMesh(.unconfigured))
        case .damaged:
            steps.append(.reportDamaged)
        }
        return steps
    }

    /// 身份**从无到有**时该补做的事 —— 只有连接那两步，不含审批与组网。
    ///
    /// 与 `steps` 分开而不是复用：那三个动作各有前置（审批已挂、组网已起），
    /// 重跑它们要么是空操作、要么会把已经在跑的组网再起一遍。
    static let identityBecameAvailable: [StartupStep] = [.activateLink, .attachEventStream]
}

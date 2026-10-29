/**
 * 启动编排的**计划** —— 一个纯函数：给定「有没有身份」与「读盘的三种结果」，
 * 回答该做哪些动作、按什么顺序做。
 *
 * 它只产出一个步骤列表，不执行、不认识任何服务。于是「启动该做什么」这件事终于能被
 * 穷举断言 —— 在此之前它散在四个 `.task` / `.onChange` 装饰器里，要跑 SwiftUI 才碰得到。
 *
 * **顺序就是依赖链，不是优先级**：组网 → 连接 → 流 → 消费方。前一步不成，后一步
 * 建起来也没有数据可走，所以按这个顺序排，读起来与真实的依赖一致。
 */
import Foundation

/// 启动时的一件事。取值就是动作本身，不含参数 —— 参数由执行方从服务上取，
/// 让计划与「服务的形状」解耦（换一个签名不会牵动这里）。
enum StartupStep: Equatable {
    /// 起组网（内部自己有 15s × 3 重试）。**它是整条链的底座**：没有地址，
    /// 后面三步都无处可去，所以排第一，且执行时等它出结论。
    case launchMesh(MeshConfig)
    /// 配置存过但读不出来：不起节点，如实说「要重填」。
    case reportDamaged
    /// 要一条连接。组网就绪时要能立刻连上，所以它的 `active` 必须早早置上。
    case activateLink
    /// 登记事件流。必须晚于 `activateLink` —— 它开流时会经 `ensureConnected` 读 `active`。
    case attachEventStream
    /// 挂审批的事件听众。**消费方排在最后**：它要的就是「流开出来之后」这件事，
    /// 而在此之前的注册都只是往事件流上挂闭包，挂在没连接时也行、但排在依赖链尾端
    /// 读起来才与真实关系一致。
    case attachApprovals
}

enum StartupPlan {

    /// 启动该走的步骤。
    ///
    /// - Parameters:
    ///   - hasIdentity: 此刻有没有设备凭证。
    ///   - config: 读盘的三种结果（`missing` / `damaged` / `ok`）。
    ///
    /// 三条规则写在这里，各自对着一类会静默出错的处境：
    /// 1. **组网排第一**：它是底座。后面三步在它没成时都不会产生任何数据，
    ///    所以执行方**等它出结论**再往下走 —— 顺序与「等」是同一件事，不是两个决定。
    /// 2. **无身份不激活连接**：无票换，连上也白连；连接层会把「无票」当终态收成 `.idle`，
    ///    所以连了也没用，反而在日志里留下一条误导的握手尝试。
    /// 3. **`damaged` 不交给节点**：`launchMesh` 的入参只有「完整配置」与「未配置」两种，
    ///    而 `damaged` 走 `reportDamaged` —— 把坏配置当空配置起节点会报「不可达」，
    ///    用户按那句提示去查 VPS 与证书，而归因从一开始就错了。
    static func steps(hasIdentity: Bool, config: MeshConfig.ReadOutcome) -> [StartupStep] {
        // ① 组网：底座。两种读盘结果各自落一个动作，都在最前面。
        var steps: [StartupStep]
        switch config {
        case .ok(let config):
            steps = [.launchMesh(config)]
        case .missing:
            // 干净首启：起一个「未配置」的节点，让状态机给出 `needsSetup`，
            // 界面据此引导去设置页填地址。
            steps = [.launchMesh(.unconfigured)]
        case .damaged:
            steps = [.reportDamaged]
        }

        // ② 连接与流：有身份才做。
        if hasIdentity {
            steps.append(.activateLink)
            steps.append(.attachEventStream)
        }

        // ③ 消费方：审批挂在流上，排在最后。
        steps.append(.attachApprovals)
        return steps
    }

    /// 身份**从无到有**时该补做的事 —— 只有连接那两步，不含审批与组网。
    ///
    /// 与 `steps` 分开而不是复用：另外两个各有前置（审批已挂、组网已起），
    /// 重跑它们要么是空操作、要么会把已经在跑的组网再起一遍。
    static let identityBecameAvailable: [StartupStep] = [.activateLink, .attachEventStream]
}

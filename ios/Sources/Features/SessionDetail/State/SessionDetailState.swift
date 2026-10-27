/**
 * 会话详情这一屏的容器：这一屏由哪些部件构成，以及跨部件的值怎么折。
 *
 * 只做三件事 —— 字段声明、`init` 里一次造齐、折值。**不取数、不判断业务值**：
 * 文件里出现 `Task` 或 `async` 成员即越界（编排归各部件自己）。
 *
 * 判据不按 `await` 判：部件自己的取数闭包就写在构造那一行里
 * （`ModelCatalogState { try await fetchCatalog(client) }`），那是部件的活。
 * 容器真要越界，长出来的必是 `Task {` 或一个 `async` 方法。
 *
 * 为什么需要它：这一屏有四个独立交互域（消息同步 / 模型目录 / 命令目录 / 输入条），
 * 而消费者要读的是「合起来的样子」（功能条那三格）。折法只在容器里一处：视图只接一个
 * 参数，不然「改一格显示什么」要在一份几百行的渲染代码里找。
 *
 * 它自己不带 `@Observable`：字段全是 `let`，它不发布任何东西。视图读
 * `detail.stripModel(...)` 时建立的是对**部件**的追踪（真正的可变状态在那里），
 * 所以刷新粒度与直接读部件一致。
 */
import Foundation

@MainActor
final class SessionDetailState {

    let session: SessionSummary
    let sync: SessionSync
    let catalog: ModelCatalogState
    let commands: CommandDirectory
    let composer: ComposerState

    init(client: RpcClient, session: SessionSummary, link: LongConnection) {
        self.session = session
        sync = SessionSync(client: client, sessionId: session.id, link: link)
        catalog = ModelCatalogState { try await fetchCatalog(client) }
        commands = CommandDirectory { try await fetchCommands(client, sessionId: session.id) }
        composer = ComposerState()
    }

    /// 功能条三格的值 —— 从编排取数转成显示值的唯一一处。
    ///
    /// 兜底规则：选中值 ?? 目录默认 ?? 未知。目录默认值只为「重拉期间不闪成未知」；
    /// 等级名与模型名读同一个 `shown`，两处各取一份会出现「模型是 A、等级是 B」。
    ///
    /// `meshPath` 由调用方给：它属于跨屏的连接域上下文（`MeshStore`），不归这一屏持有 ——
    /// 折值可以要一个值，但不该因此把那个对象拉进来。
    func stripModel(meshPath: CarrierPath?) -> ComposerStripModel {
        let shown = sync.displayedModel ?? catalog.lastKnownDefault
        return ComposerStripModel.make(
            phase: sync.phase,
            carrier: meshPath,
            usage: sync.usage,
            modelName: modelDisplayName(shown),
            effortName: catalog.effortLabel(for: shown)
        )
    }

    /// 内容还没到 —— 此刻不挂 List（理由见视图：空列表先出现会让初始布局落在顶部）。
    var isTranscriptEmpty: Bool { sync.eventCount == 0 }
}

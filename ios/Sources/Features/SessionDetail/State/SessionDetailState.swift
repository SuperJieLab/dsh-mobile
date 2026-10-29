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
 * 而消费者要读的是「合起来的样子」（功能条那三格）。折法只在容器里一处，不然
 * 「改一格显示什么」要在一份几百行的渲染代码里找。
 *
 * 它自己不带 `@Observable`：字段全是 `let`，它不发布任何东西。视图读
 * `detail.stripModel()` 时建立的是对**部件**的追踪（真正的可变状态在那里），
 * 所以刷新粒度与直接读部件一致。
 *
 * **引用 ≠ 拥有**：`store` 与 `approvals` 是根造的、与进程同寿。这一屏关掉不会
 * 清空待答表（停在列表时它照样在收），也不会重置组网草稿；容器只是把它们放在一起，
 * 让渲染段不必分别认识它们。
 *
 * 折值只在两种情形做：要**组合**两处（`stripModel` / `pendingApprovals` / `notice`），
 * 或同一个值被读两处以上（网络 sheet 的三连）。其余读穿到部件，不在这里抄一遍。
 */
import Foundation

@MainActor
final class SessionDetailState {

    let session: SessionSummary
    let sync: SessionSync
    let catalog: ModelCatalogState
    let commands: CommandDirectory
    let composer: ComposerState
    /// 组网事实的来源（节点五态、路径、配置读坏）—— 这一屏只读，配置入口在设置页。
    let store: MeshStore
    /// App 级的待答表 —— 这一屏只读它按会话分出来的那一栏。
    let approvals: ApprovalStore

    init(client: RpcClient,
         session: SessionSummary,
         link: LongConnection,
         store: MeshStore,
         approvals: ApprovalStore) {
        self.session = session
        self.store = store
        self.approvals = approvals
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
    /// 载体那一路读连接域的投影（`meshPath`）—— 它不归这一屏持有，但这一屏要读它。
    func stripModel() -> ComposerStripModel {
        let shown = sync.displayedModel ?? catalog.lastKnownDefault
        return ComposerStripModel.make(
            phase: sync.phase,
            // 组网那一步的处境：`.awaitingMesh` 时这一格的说法由它定 ——
            // 「等」只在真的在注册时才准确。
            mesh: store.phase,
            carrier: meshPath,
            usage: sync.usage,
            modelName: modelDisplayName(shown),
            effortName: catalog.effortLabel(for: shown)
        )
    }

    /// 内容还没到 —— 此刻不挂 List（理由见视图：空列表先出现会让初始布局落在顶部）。
    var isTranscriptEmpty: Bool { sync.eventCount == 0 }

    /// 本会话还挂着的卡。表按会话分组，这一屏只取这一栏。
    var pendingApprovals: [ApprovalTable.Entry] { approvals.pending(in: session.id) }

    /// 这一屏的审批提示（"已过期"这类），没有时是 nil。
    var notice: String? { approvals.notice(for: session.id) }

    /// 徽章与网络 sheet 读的路径投影 —— 同一个值三处读，折在这里一处。
    var meshPath: CarrierPath? { store.meshPath }
    /// 节点五态。
    var nodeState: TailnetNodeState { store.nodeState }
    /// 存过的组网配置读不出来。
    var configDamaged: Bool { store.storedConfigDamaged }
}

/**
 * 会话详情这一屏的容器：由哪些部件构成，跨部件的值怎么折。
 *
 * **不取数、不判断业务值**：出现 `Task` 或 `async` 成员即越界（编排归部件自己）。
 * 折值只在「要组合两处」或「同一个值被读两处以上」时做，其余读穿到部件。
 */
import Foundation

@MainActor
final class SessionDetailState {

    /// 这一屏认的会话身份与标题。**只要这两格** —— 摘要里的 `blank` / `origin` / 时间戳
    /// 这一屏一个都不读，留着它们等于让每个调用方先凑一份完整摘要（新建会话就凑不出来）。
    let sessionId: String
    /// 会话标题；没有（新建的空会话）时界面显示「会话」。
    let title: String?
    let sync: SessionSync
    let catalog: ModelCatalogState
    let commands: CommandDirectory
    let composer: ComposerState
    /// 组网事实的来源（节点五态、路径、配置读坏）—— 这一屏只读，配置入口在设置页。
    let store: MeshStore
    /// App 级的待答表 —— 这一屏只读它按会话分出来的那一栏。
    let approvals: ApprovalStore

    init(client: RpcClient,
         sessionId: String,
         title: String?,
         link: LongConnection,
         store: MeshStore,
         approvals: ApprovalStore) {
        self.sessionId = sessionId
        self.title = title
        self.store = store
        self.approvals = approvals
        sync = SessionSync(client: client, sessionId: sessionId, link: link)
        catalog = ModelCatalogState { try await fetchCatalog(client) }
        commands = CommandDirectory { try await fetchCommands(client, sessionId: sessionId) }
        composer = ComposerState()
    }

    /// 功能条三格的值 —— 从编排取数转成显示值的唯一一处。
    ///
    /// 兜底规则：选中值 ?? 目录默认 ?? 未知。目录默认只为「重拉期间不闪成未知」；
    /// 等级名与模型名读同一个 `shown`，两处各取一份会出现「模型是 A、等级是 B」。
    func stripModel() -> ComposerStripModel {
        let shown = sync.displayedModel ?? catalog.lastKnownDefault
        return ComposerStripModel.make(
            phase: sync.phase,
            // `.awaitingMesh` 这一格的说法由组网处境定 ——「等」只在真在注册时准确。
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
    var pendingApprovals: [ApprovalTable.Entry] { approvals.pending(in: sessionId) }

    /// 这一屏的审批提示（"已过期"这类），没有时是 nil。
    var notice: String? { approvals.notice(for: sessionId) }

    /// 徽章与网络 sheet 读的路径投影 —— 同一个值三处读，折在这里一处。
    var meshPath: CarrierPath? { store.meshPath }
    /// 节点五态。
    var nodeState: TailnetNodeState { store.nodeState }
    /// 存过的组网配置读不出来。
    var configDamaged: Bool { store.storedConfigDamaged }
}

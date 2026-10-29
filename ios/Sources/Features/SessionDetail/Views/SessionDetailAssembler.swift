import SwiftUI

/// 会话详情的装配段：造容器、接线（进屏开流、离屏关卡），交给渲染段。
/// **容器由这一屏自己造**：它要随这一屏生死（离开就丢，回来重取一个窗口），
/// 依赖在签名上看得见：四个服务 —— 这一屏要什么，读签名就知道，不必跳到组合根。
struct SessionDetailAssembler: View {
    private let session: SessionSummary
    private let client: RpcClient
    private let link: LongConnection
    private let store: MeshStore
    private let approvals: ApprovalStore

    /// 首帧为 nil：容器在 `.task` 里现造。`@State` 的初值表达式每次视图重建都求值、
    /// 只采用第一个 —— 造在 `init` 里不会错（构造是纯的），但会白造好几次。
    @State private var detail: SessionDetailState?

    init(session: SessionSummary,
         client: RpcClient,
         link: LongConnection,
         store: MeshStore,
         approvals: ApprovalStore) {
        self.session = session
        self.client = client
        self.link = link
        self.store = store
        self.approvals = approvals
    }

    var body: some View {
        Group {
            if let detail {
                SessionDetailView(detail: detail)
            } else {
                // 首帧：容器还没造出来。这一帧由这句吸收，与「正在同步」是同一个面。
                ProgressView("正在同步…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 进屏即登记一条流：opening 给首屏，事件与未定稿实时推。
        // 离屏即注销那一条。`sync()`（HTTP 全量对齐）只留作首屏兜底。
        // 连接不归本屏：回前台与组网就绪的重连点在组合根上 —— 那是 App 级事件。
        .task {
            if detail == nil {
                detail = SessionDetailState(client: client,
                                            session: session,
                                            link: link,
                                            store: store,
                                            approvals: approvals)
            }
            guard let created = detail else { return }
            created.sync.startFollowing()
            // 目录进屏拉一次。挂在格子上的话，功能条每次因键盘收起而重建都会重拉一遍。
            await created.catalog.reload()
            // 离屏时这个 `.task` 会被取消。若 `onDisappear` 早于这里执行，它看到的
            // `detail` 还是 nil，那条流就没人关 —— 关一次是幂等的，这里补上。
            if Task.isCancelled { created.sync.stopFollowing() }
        }
        .onDisappear { detail?.sync.stopFollowing() }
    }
}

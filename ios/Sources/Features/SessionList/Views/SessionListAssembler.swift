import SwiftUI

/// 会话列表的装配段：造 `SessionListState`、把它接到事件流上，交给渲染段。
///
/// **状态由这一屏自己造**：它是栈根，`NavigationStack` 保留根视图，
/// 推入详情再返回时 `@State` 不丢，列表停在原地、不重拉一遍。
///
/// 订阅接线也跟着 state 走 —— 它以前挂在组合根上，唯一的理由是「根造这个 state」。
/// 造的人变了，这条线就跟着变。
struct SessionListAssembler: View {
    private let client: RpcClient
    /// 订阅要它：列表「跟着别的设备动」全靠这条流。
    private let events: EventStream
    /// 渲染段读它的投影：`phase` 驱动「就绪即首载」，`meshPath` 给徽章，`route` 给页脚地址。
    private let store: MeshStore

    /// 首帧为 nil：容器在 `.task` 里现造。`@State` 的初值表达式每次视图重建都求值、
    /// 只采用第一个 —— 造在 `init` 里不会错（构造是纯的），但会白造好几次；造在这里只造一次。
    @State private var list: SessionListState?

    init(client: RpcClient, events: EventStream, store: MeshStore) {
        self.client = client
        self.events = events
        self.store = store
    }

    var body: some View {
        Group {
            if let list {
                SessionListView(list: list, store: store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if list == nil { list = SessionListState(client: client) }
            // `attach` 自带闸：`.task` 在详情推入时取消、返回时重跑，重跑这一下是空操作。
            list?.attach(events: events)
        }
    }
}

import SwiftUI

/// 会话列表的装配段：造 `SessionListState`、把它接到事件流上，交给渲染段。
/// **状态由这一屏自己造**：它是栈根，`NavigationStack` 保留根视图，
/// 订阅接线跟着 state 走：造它的地方就是接它的地方 —— 挂在别处，读的人要在两个文件之间
/// 对「谁让它更新」，两处任一改动都能让列表静默不更新。
struct SessionListAssembler: View {
    private let client: RpcClient
    /// 订阅要它：列表「跟着别的设备动」全靠这条流。
    private let events: EventStream
    /// 渲染段读它的投影：`phase` 驱动「就绪即首载」，`meshPath` 给底部那条状态带。
    private let store: MeshStore
    /// 新建成功后要进哪一屏。由组合根给（那里握着 `NavigationStack` 的 path）。
    private let navigate: (Destination) -> Void

    /// 首帧为 nil：容器在 `.task` 里现造。`@State` 的初值表达式每次视图重建都求值、
    /// 只采用第一个 —— 造在 `init` 里不会错（构造是纯的），但会白造好几次；造在这里只造一次。
    @State private var list: SessionListState?

    init(client: RpcClient,
         events: EventStream,
         store: MeshStore,
         navigate: @escaping (Destination) -> Void) {
        self.client = client
        self.events = events
        self.store = store
        self.navigate = navigate
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
            if list == nil {
                // 装配段把两个方向都对上：状态只管「建好了、id 是这个」，
                // 推进哪一屏由握着栈的人决定。
                list = SessionListState(client: client) { sessionId in
                    navigate(.session(sessionId: sessionId, title: nil))
                }
            }
            // `attach` 自带闸：`.task` 在详情推入时取消、返回时重跑，重跑这一下是空操作。
            list?.attach(events: events)
        }
    }
}

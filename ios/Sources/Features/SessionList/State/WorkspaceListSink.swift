/**
 * 列表从组流上要的两件事：当前组清单，与「它变了」。
 *
 * **收窄成协议而不是吃具体类**（与 `SessionListEventSink` 同一条理由）：列表状态不该认识
 * 「流怎么开、帧怎么判」。收窄之后它的测试可以把组流替掉 —— 不需要一条真连接来证明
 * 「组清单换了、列表跟着重算」。
 */
import Foundation

@MainActor
protocol WorkspaceListSource {
    /// 当前组清单，顺序即显示顺序。
    var workspaces: [WorkspaceView] { get }
    /// 组清单或两个集合变了一次。返回退订闭包。
    @discardableResult
    func onWorkspacesChanged(_ handler: @escaping () -> Void) -> () -> Void
}

/// 把 `WorkspaceStream` 收窄成列表要的那两件事。
struct WorkspaceListSink: WorkspaceListSource {

    private let stream: WorkspaceStream

    init(stream: WorkspaceStream) {
        self.stream = stream
    }

    var workspaces: [WorkspaceView] { stream.workspaces }

    @discardableResult
    func onWorkspacesChanged(_ handler: @escaping () -> Void) -> () -> Void {
        stream.updateListeners.add { _ in handler() }
    }
}

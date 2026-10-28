import SwiftUI

/// 配对屏的装配段：造容器、交给渲染段。容器随这一屏生死（草稿不跨进出）。
///
/// 三个动作以**闭包**注入，不持服务：三件事各对应一个闭包，
/// 而它不需要 `RpcClient` 的任何其它能力。签名说不出凭证存在哪，也发不出请求。
struct PairingAssembler: View {
    private let submit: (String) async throws -> Void
    private let hasIdentity: () -> Bool
    private let discardIdentity: () -> Void

    /// 首帧为 nil：容器在 `.task` 里现造。`@State` 只采用第一个值 —— 造在 `init` 里
    /// 不会错（构造是纯的），但会白造好几次。
    @State private var state: PairingState?

    init(submit: @escaping (String) async throws -> Void,
         hasIdentity: @escaping () -> Bool,
         discardIdentity: @escaping () -> Void) {
        self.submit = submit
        self.hasIdentity = hasIdentity
        self.discardIdentity = discardIdentity
    }

    var body: some View {
        Group {
            if let state {
                PairingView(state: state)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if state == nil {
                state = PairingState(submit: submit,
                                     hasIdentity: hasIdentity,
                                     discardIdentity: discardIdentity)
            }
        }
    }
}

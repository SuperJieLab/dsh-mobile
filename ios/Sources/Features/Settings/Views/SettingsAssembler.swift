import SwiftUI

/// 设置页的装配段：造 `SettingsState`，交给渲染段。
///
/// 它只被这一页消费，所以状态归这一页 —— 一个消费者的可变状态没有理由与进程同寿。
/// 两个身份动作以闭包注入，它不认识 `RpcClient`，也不知道凭证存在哪。
struct SettingsAssembler: View {
    private let store: MeshStore
    private let logFile: LogFile
    private let telemetryStore: TelemetryStore
    private let hasIdentity: () -> Bool
    private let discardIdentity: () -> Void

    @State private var state: SettingsState?

    init(store: MeshStore,
         logFile: LogFile,
         telemetryStore: TelemetryStore,
         hasIdentity: @escaping () -> Bool,
         discardIdentity: @escaping () -> Void) {
        self.store = store
        self.logFile = logFile
        self.telemetryStore = telemetryStore
        self.hasIdentity = hasIdentity
        self.discardIdentity = discardIdentity
    }

    var body: some View {
        Group {
            if let state {
                SettingsView(state: state)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if state == nil {
                state = SettingsState(store: store,
                                      logFile: logFile,
                                      telemetryStore: telemetryStore,
                                      hasIdentity: hasIdentity,
                                      discardIdentity: discardIdentity)
            }
        }
    }
}

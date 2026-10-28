import SwiftUI

/// 组网设置的装配段：造 `MeshSetupState`、读一次盘填草稿，交给渲染段。
///
/// **草稿只属这一页** —— 离开就丢，与配对码同理。它曾经住进程级，理由是「设置页也要它」；
/// 而那个理由的实物依据（`SettingsState.setup`）是个零读取的死字段。路径只剩这一条之后，
/// 理由连同字段一起消失。
///
/// 两个动作以闭包注入：它不认识 `MeshStore`，只认识「提交一份」与「按存下来的那份重试」。
struct MeshSettingsAssembler: View {
    private let store: MeshStore

    @State private var setup: MeshSetupState?

    init(store: MeshStore) {
        self.store = store
    }

    var body: some View {
        Group {
            if let setup {
                MeshSettingsView(setup: setup, store: store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard setup == nil else { return }
            // 取成局部量再进闭包：捕获列表里的标识符不走隐式 `self`。
            let store = self.store
            let created = MeshSetupState(
                stored: .unconfigured,
                submit: { [weak store] key, config in await store?.submitMeshKey(key, config: config) },
                retry: { [weak store] config in await store?.retryMesh(config: config) }
            )
            // 盘上的那份在这一刻读一次，填进草稿。**读在这里而不在构造里**：`@State` 的初值
            // 表达式会求值多次，构造里读盘会在那几次里各留一道痕迹。
            //
            // 只在这一处填（`setup == nil` 那一支）：草稿建好之后 `.task` 若重跑，盘上那份
            // 不该再覆盖用户正在敲的字。读坏的配置不填 —— 与根上那一支同一条规则，提示由
            // `store.storedConfigDamaged` 给。
            if case .ok(let config) = MeshConfig.read() { created.adoptStored(config) }
            setup = created
        }
    }
}

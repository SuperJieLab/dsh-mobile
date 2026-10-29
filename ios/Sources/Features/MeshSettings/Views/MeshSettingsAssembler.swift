import SwiftUI

/// 组网设置的装配段：造 `MeshSetupState`、让它读一次盘填草稿，交给渲染段。
/// **草稿只属这一页** —— 离开就丢，与配对码同理。它不需要与别处共享：到达这一页的路径
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
            // 取成局部量再进闭包：闭包要的是这一份 `store`，不是「视图是什么」。
            // 闭包直接持有它（不弱化）：`store` 活满进程，弱捕获换来的只是一个够不着的
            // 分支，而那个分支只能编一个假答案。
            let store = self.store
            let created = MeshSetupState(
                stored: .unconfigured,
                submit: { key, config in await store.submitMeshKey(key, config: config) },
                retry: { config in await store.retryMesh(config: config) },
                isStarting: { store.isStarting }
            )
            // 盘上的那份由状态自己读：读盘归它那一层，视图层只决定「什么时候读」。
            // 只在这一处读（`setup == nil` 那一支）—— 草稿建好之后 `.task` 若重跑，
            // 盘上那份不该再覆盖用户正在敲的字。
            created.adoptStoredFromDisk()
            setup = created
        }
    }
}

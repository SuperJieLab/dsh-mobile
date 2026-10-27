/**
 * 组网设置这一页的依赖面：录入草稿（`MeshSetupState`）+ 节点事实（`MeshStore` 的只读投影）。
 *
 * 为什么需要这一层：这个页面有两条抵达路径（设置页里那一行、组网未就绪时的整屏），
 * 而它们与组网之间隔着两层自己不用这些对象的视图 —— 用构造参数传，就把「转发」塞进了
 * 列表与选屏。放在这里，视图只接一个参数。
 *
 * **引用 ≠ 拥有**：两个字段都是根造的、与进程同寿。这一层只是把它们放在一起给一个视图读 ——
 * 容器重造不会重置草稿（两个入口共用一份），也不会重启节点。
 */
import Foundation

@MainActor
final class MeshSettingsState {
    /// 录入与提交（两份地址、接入密钥、保存并接入、按存下来的那份重试）。
    let setup: MeshSetupState
    /// 节点五态与「配置读坏了」的来源。只读 —— 动手的入口在 `setup`。
    let store: MeshStore

    init(setup: MeshSetupState, store: MeshStore) {
        self.setup = setup
        self.store = store
    }
}

/**
 * 会话列表这一屏的依赖面：列表（取数、可见性、事件回放）+ 连接域的只读投影 + 页脚那句地址。
 *
 * 为什么需要这一层：视图原先除了列表状态还从环境里取两样（`MeshStore` 的 `phase` 与
 * `meshPath`），签名上看不出它依赖三件事。放进这里，视图只接一个参数。
 *
 * 地址为什么在这里而不在 `SessionListState`：那条状态只管「取回来是什么」；地址属于连接域
 * （端点换过就变），与取数没有关系。给的是**闭包**而不是端点对象 —— 这一层只需要一句字。
 *
 * 它不参与观察：闭包里读的是不可观察的端点。页脚之所以会跟着变，是因为整屏在
 * `meshSettings.store.phase` 变化时重算 —— 那条依赖在视图的 `onChange` 里，不在这里。
 *
 * **引用 ≠ 拥有**：`meshSettings` 是根造的、与进程同寿。重进这一屏不会重置组网草稿，
 * 也不会重启节点；这一层只是把三样放在一起给一个视图读。
 */
import Foundation

@MainActor
final class SessionListScreenState {
    let list: SessionListState
    /// 组网设置的依赖面 —— 未就绪的整屏与设置页都从它取。
    let meshSettings: MeshSettingsState
    /// 设置页的依赖面（组网 + 身份）。
    let settings: SettingsState
    private let address: () -> String

    init(list: SessionListState,
         meshSettings: MeshSettingsState,
         settings: SettingsState,
         address: @escaping () -> String) {
        self.list = list
        self.meshSettings = meshSettings
        self.settings = settings
        self.address = address
    }

    /// 组网阶段 —— 「就绪即首载」那一处 `onChange` 读它。
    var phase: MeshPhase { meshSettings.store.phase }

    /// 徽章的路径。
    var meshPath: CarrierPath? { meshSettings.store.meshPath }

    /// 页脚那句地址。
    var addressLine: String { address() }
}

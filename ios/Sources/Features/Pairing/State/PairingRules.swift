/**
 * 配对屏的两条提交规则 —— 配对码能不能提交、组网录入能不能提交。
 *
 * 纯判定：入参就是全部输入，不读全局状态、不 import SwiftUI。
 *
 * 独立成类型而不是 `PairingState` 上的属性：`PairingState` 的构造要一个 `RpcClient`，
 * 而它是 `final class`、没有协议 —— 规则挂在它身上，断言就得先造门面替身，而替身只能伪造
 * 我们自己的端口，测不出自己的错。
 *
 * 输入值的**持有者**仍各在各处：配对码与「正在提交」在 `PairingState`，两份地址与接入密钥
 * 在 `MeshSetupState` —— 两个状态源按「换的是什么」划分（身份 / 路径）。规则不挂在它们身上，
 * 是因为那两处的构造都要外部依赖，而规则要能在不构造任何状态对象的条件下载跑。
 */
import Foundation

enum PairingRules {

    /// 配对码能不能提交：满 6 位且没有正在进行的提交。
    ///
    /// **只判长度，不判字符集**：配对码由服务端发放，前端若比服务端更严，用户粘贴一个带字母的码
    /// 时会看到按钮灰着、却没有任何解释 —— 比「点一次，让服务端说它不行」更糟。
    static func canSubmitCode(_ code: String, isSubmitting: Bool) -> Bool {
        !isSubmitting && code.count == 6
    }

    /// 组网段能不能提交：接入密钥非空，且两份地址构成完整配置。
    static func canSubmitMesh(key: String, config: MeshConfig) -> Bool {
        !key.isEmpty && config.isComplete
    }
}

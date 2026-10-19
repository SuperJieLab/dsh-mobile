/**
 * 配对屏的两条提交规则 —— 配对码能不能提交、组网录入能不能提交。
 *
 * 纯判定：入参就是全部输入，不读任何全局状态、不 import SwiftUI（判据在
 * `tests/PairingRulesTests.swift`，不需要网络、界面或状态对象）。
 *
 * 为什么是独立类型而不是 `PairingState` 上的属性：`PairingState` 的构造要一个
 * `GatewayClient`，而它是 `final class`、没有协议 —— 把规则挂在它身上，断言就得先造一个
 * 门面替身，而替身只能伪造我们自己的端口，测不出自己的错。
 *
 * 输入值的**持有者**仍各在各处：配对码与「正在提交」在 `PairingState`（它转发类中的第一条），
 * 组网的地址与密钥在视图的 `@State`（R16 期1 决定 B3：组网段不搬进判定层）。
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

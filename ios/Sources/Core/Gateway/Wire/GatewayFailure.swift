/**
 * 与链路无关的失败词汇：协议版本、错误码、失败信封。
 *
 * 两条链路都用它 —— 一元的 `ok:false` 与流帧的 `refused` 共用同一套码，所以它不能住在
 * 任何一条链路的目录里。
 */
import Foundation

/// 失败信封里的错误码。
///
/// 收的时候刻意用 `String` 而非本枚举：上游加码时照原样显示，不能解不出来就崩。
/// `CaseIterable` 只为那一条「取值只写一处」的检查（`tests/ErrorCodeLiteralTests.swift`）。
///
/// **没有版本码**：新版协议没有版本字段，「旧客户端连新网关」表现为 404（端点不在表里），
/// 那是传输层的处境，不是协议内的码。
enum GatewayErrorCode: String, CaseIterable {
    /// 流通道里「这个名字没有端点」。一元的同名情形以 404 出现，不走这个码 ——
    /// 但两端共用一套词汇，所以枚举里有它。
    case unknownEndpoint = "unknown-endpoint"
    case unknownSession = "unknown-session"
    case unreadableSession = "unreadable-session"
    case internalError = "internal-error"
    /// 这条流要的源还没就绪 —— 网关没有它此刻的集合，于是拒绝开流而不是给一份旧的。
    /// 客户端按**可重试**处理：源接上之后再开一条就好了。
    case sourceUnavailable = "source-unavailable"
    case resyncRequired = "resync-required"
    case unauthenticated = "unauthenticated"
    case unknownApproval = "unknown-approval"
    /// 这条流不归你：它是别人的、已经换代了，或者这个身份根本不许答审批。
    /// 与 `unknown-approval` 分开是因为「换一条流再试」对前者可能有用，对后者没有 ——
    /// 但两者对客户端的处置相同（撤卡，等重投）。
    case notOwner = "not-owner"
    case invalidRequest = "invalid-request"
    case sessionModelUnavailable = "session/model-unavailable"
    case windowTooLarge = "window-too-large"
    /// 那一行解析不出已注册的命令名，或语法不对 —— 用户改字就能修好，与「执行失败」不同。
    case unknownCommand = "unknown-command"
    /// 这个名字不在宿主此刻的权限目录里（插件装卸、装配改过）—— 重拉一次目录再选。
    case unknownPreset = "unknown-preset"
}

/// 失败信封里的 `error` 对象：三键恒定。
///
/// `details` 是每个错误码自带结构化信息的地方，没有时是空字典 —— 与流通道的失败对象
/// 同形。它不参与任何分支判断（分支只看 `code`），落在这里是为了留痕与排障。
struct GatewayFailure: Decodable, Equatable {
    let code: String
    let message: String
    /// 缺省给空字典：**必填是服务端的义务，客户端不接受「缺一格就整条失败」** ——
    /// 那会把一条可读的拒绝退化成「报文畸形」。
    var details: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey { case code, message, details }

    /// 手写而不是靠合成：`Decodable` 的合成**不看属性默认值** —— 属性写了 `= [:]`，
    /// 缺这一格时它照样抛 `keyNotFound`。默认值只对「有人手动构造」那一侧生效，
    /// 解码路径必须显式 `decodeIfPresent`。这也是流通道 `FailurePayload` 的同一套规则：
    /// 两条通道对同一格不能一个严一个宽。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        // `try?` 而不是 `try`：`details` 是**排障用的附加信息**，它形状不对（比如服务端
        // 给了字符串）不该把一条可读的拒绝退化成「报文畸形」。流通道的 `FailurePayload`
        // 用的是同一条规则 —— 两条通道对同一格宽严一致。
        details = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .details)) ?? [:]
    }

    init(code: String, message: String, details: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

extension GatewayFailure {

    /// 再开一条同样的流，答复**可能不同**吗。
    ///
    /// 依据只有一句：上游这一次的答复会不会变。`source-unavailable`（源这一代还没就绪）
    /// 与 `internal-error`（网关这一侧的临时故障）会变；`unknown-session`、`unauthenticated`
    /// 再试一万次也一样。
    ///
    /// **为什么这一格住在这里而不是流层**：流层只该认编号与答复，认识协议错误码就说明
    /// 它开始理解业务之外的词汇了。这个判断与 `GatewayErrorCode` 同源，离它最近的地方
    /// 是错误值自己。
    var isRetryable: Bool {
        code == GatewayErrorCode.sourceUnavailable.rawValue
            || code == GatewayErrorCode.internalError.rawValue
    }
}

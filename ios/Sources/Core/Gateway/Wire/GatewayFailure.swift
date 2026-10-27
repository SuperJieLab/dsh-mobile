/**
 * 与链路无关的失败词汇：协议版本、错误码、失败信封。
 *
 * 两条链路都用它 —— 一元的 `ok:false` 与流帧的 `refused` 共用同一套码，所以它不能住在
 * 任何一条链路的目录里。
 */
import Foundation

/// 协议版本，请求与响应都必须带它 —— 版本协商的位置。
let gatewayProtocolVersion = 2

/// 失败信封里的错误码（协议 v2 七个 + `unauthenticated` + `unknown-approval` /
/// `invalid-request` + `session/model-unavailable` + `window-too-large` + `unknown-command`）。
/// 收的时候刻意用 `String` 而非本枚举：上游加码时照原样显示，不能解不出来就崩。
/// `CaseIterable` 只为那一条「取值只写一处」的检查（`tests/ErrorCodeLiteralTests.swift`）：
/// 判据遍历 `allCases`，不必去解析源码猜协议里有哪些码。生产代码不遍历它。

enum GatewayErrorCode: String, CaseIterable {
    case unsupportedVersion = "unsupported-version"
    case unknownOp = "unknown-op"
    case unknownSession = "unknown-session"
    case unreadableSession = "unreadable-session"
    case internalError = "internal-error"
    /// 这条流要的源还没就绪 —— 网关没有它此刻的集合，于是拒绝开流而不是给一份旧的。
    /// 客户端按**可重试**处理：源接上之后再开一条就好了。
    case sourceUnavailable = "source-unavailable"
    case resyncRequired = "resync-required"
    case unauthenticated = "unauthenticated"
    case unknownApproval = "unknown-approval"
    case invalidRequest = "invalid-request"
    case sessionModelUnavailable = "session/model-unavailable"
    case windowTooLarge = "window-too-large"
    /// 那一行解析不出已注册的命令名，或语法不对 —— 用户改字就能修好，与「执行失败」不同。
    case unknownCommand = "unknown-command"
}

/// 失败信封里的 `error` 对象。

struct GatewayFailure: Decodable, Equatable {
    let code: String
    let message: String
}

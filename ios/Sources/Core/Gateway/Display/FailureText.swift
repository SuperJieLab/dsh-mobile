/**
 * 失败怎么说给用户听 —— 错误码解释、可读描述、错误渲染。
 *
 * 与 `Contract/GatewayError.swift` 的分工：那边是词汇（有哪些失败），这边是句子与取舍
 * （怎么说）。改一句话不需要动合约（R18 B1）。
 *
 * 这一层在通信层之上，所以**不读传输层的常量** —— 超时那句因此不打印秒数（R18 期1 决定 2）。
 *
 * 消费者：`SessionSync`、`ApprovalStore`（读 `readableDescription`）；
 * 各处 `error.localizedDescription`（走本文件的 `LocalizedError`）。
 */
import Foundation

extension GatewayErrorCode {
    /// 人话解释，用于把服务端的拒绝变成用户看得懂的一句话。未知码返回 nil。
    var explanation: String? {
        switch self {
        case .unsupportedVersion:
            return "网关不认识这次请求的协议版本 —— 两端版本不一致。"
        case .unknownOp:
            return "网关不认识这个操作名 —— 客户端用了一个服务端没有的 op。"
        case .unknownSession:
            return "这个会话在 Mac 上找不到了 —— 可能已被删除。"
        case .unreadableSession:
            return "会话存在，但这个版本的 DSH 读不懂它的日志。"
        case .internalError:
            return "网关自身出错 —— 进程还活着，只是这次请求失败了。"
        case .resyncRequired:
            return "本机记的位置在 Mac 上不存在了 —— 正在从头发起一次同步。"
        case .unauthenticated:
            return "没有可用的身份 —— 未配对或配对已被撤销。"
        case .unknownApproval:
            return "这条审批已经不在了 —— 可能已被取消或在 Mac 上处理过。"
        case .invalidRequest:
            return "网关拒绝了这条写请求的载荷 —— 两端版本可能不一致。"
        case .sessionModelUnavailable:
            return "这个模型现在路由不过去 —— 换一个模型，或在 Mac 上检查凭证。"
        case .windowTooLarge:
            return "这个会话最近一轮本身就超过了一次能传的上限 —— 暂时打不开，等它有新进展后再来看。"
        }
    }
}

extension GatewayFailure {
    /// 优先给中文解释，否则回落显示服务端原文；服务端没写原因时给一句固定的。
    var readableDescription: String {
        if let explanation = GatewayErrorCode(rawValue: code)?.explanation { return explanation }
        return message.isEmpty ? "服务端拒绝了请求，但没有说明原因。" : message
    }
}

extension GatewayClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .transport(let url, let underlying):
            return Self.explain(url: url, error: underlying)

        case .badStatus(let code):
            switch code {
            case 400: return "网关说这次请求的 body 不是合法 JSON（HTTP 400）。"
            case 413: return "请求 body 超过网关的 1 MiB 上限（HTTP 413）。"
            default: return "网关回了 HTTP \(code)。"
            }

        case .malformedResponse(let detail):
            return "网关的响应读不出来：\(detail)"

        case .versionMismatch(let v):
            return "网关回的是协议 v\(v)，本客户端只会说 v\(gatewayProtocolVersion) —— 两端版本不一致。"

        case .refused(let failure):
            return failure.readableDescription

        case .unauthenticated:
            return "还没有配对，或配对已被 Mac 侧撤销 —— 请重新配对。"
        case .notActivated:
            return "组网尚未就绪 —— 等连接建立后再试。"
        }
    }

    /// 把 `URLError` 翻译成人话 —— **Step 4 真正要撞的两个坑会在这里自己报出名字**：iOS 上有两套
    /// 彼此独立的管控拦明文 HTTP 到局域网，ATS 报 `-1200`、LNP 报 `NotConnectedToInternet`，改错
    /// 地方都白改，所以必须分开说。
    private static func explain(url: URL, error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .secureConnectionFailed:
            return """
            ATS 拦下了这次明文连接（URLError -1200）。
            检查 Info.plist 里的 NSAppTransportSecurity → NSAllowsLocalNetworking。
            """
        case .notConnectedToInternet:
            return """
            本地网络隐私（LNP）拦下了这次请求（URLError -1009）。这不是「没网」——
            到「设置 → 隐私与安全性 → 本地网络」里允许本 App。
            该列表只在 App 请求过之后才出现；拒绝过就把它删掉重装，弹窗会再来一次。
            """
        case .cannotConnectToHost, .cannotFindHost:
            return """
            连不上 \(url.host ?? "?"):\(url.port.map(String.init) ?? "?")。
            三件事按序查：① Mac 上的 dsh 还在跑吗（端口 3081 有没有在听）
            ② 手机和 Mac 是同一个 Wi-Fi 吗 ③ 路由器有没有开 AP 客户端隔离。
            """
        case .timedOut:
            return "请求超时 —— 地址可能写错了，或者中间有东西在丢包。"
        default:
            return "网络错误 \(urlError.code.rawValue)：\(urlError.localizedDescription)"
        }
    }
}

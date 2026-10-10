import Foundation

/// 对 Mac 网关的**纯传输层**（R2 从 `GatewayClient` 拆出，函数体逐字搬移）：
/// 拼请求、发一次 `POST /rpc`、按 HTTP 状态与信封判成败、把 URLError 翻成人话。
///
/// 切分判据 = 「改了要不要升协议版本」（R2 Plan §三）：这里的代码不碰协议语义 ——
/// 消息结构在 `GatewayProtocol.swift`，身份状态机（pair / 续期单飞 / `isPaired`）留在
/// `GatewayClient`，它调本类发送。
@MainActor
final class GatewayTransport {
    let baseURL: URL

    /// 承载请求的 session（M8 决定 4）：默认 `shared`（局域网直连，行为不变）；
    /// 组网后注入 `TailnetNode.gatewaySession`（SOCKS5 回环 → tailnet），消息层零感知。
    private let session: URLSession

    /// 协议里的唯一端点。多端点会把资源语义烧进 URL（见 `docs/dev/protocol.md` §二）。
    nonisolated static let rpcPath = "/rpc"

    /// 请求超时。局域网直连正常是毫秒级，10 秒只用来兜住「地址写错」这种情况。
    nonisolated static let timeout: TimeInterval = 10

    /// 三张票在手机侧的家（M4）。默认共享单例：全 App 一个身份。
    let credentials: CredentialStore

    init(baseURL: URL, credentials: CredentialStore, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
    }

    /// 发一次（不带续期编排）。返回 `nil` 表示被 401 拒了 —— 续期单飞与重试
    /// 恰好一次的编排是身份状态机，留在 `GatewayClient.send`。
    func sendOnce<Request: Encodable, Response: Decodable>(
        _ request: Request,
        authenticated: Bool,
        type: Response.Type
    ) async throws -> Response? {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(Self.rpcPath))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 身份只走传输头，不进消息体（docs/dev/protocol.md §「身份」）。
        if authenticated, let access = credentials.validAccessToken() {
            urlRequest.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.timeoutInterval = Self.timeout
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let payload: Data
        let urlResponse: URLResponse
        do {
            (payload, urlResponse) = try await session.data(for: urlRequest)
        } catch {
            // 请求没发出去或没回来：读链路唯一的服务端外故障点，必须留痕。
            Log.warn(Log.Module.gateway, "transport: \(error.localizedDescription) (base=\(baseURL.host ?? "?"))")
            throw GatewayClientError.transport(url: urlRequest.url ?? baseURL, underlying: error)
        }

        if let http = urlResponse as? HTTPURLResponse {
            guard http.statusCode != 401 else {
                // 业务请求的 401 是「换个票再来」的信号，返回 nil 交外层续期重试；鉴权请求
                // （pair / refresh）的 401 自带语义，必须读出信封上抛：配对码不对要说配对码不对。
                guard authenticated else {
                    if let failure = envelopeFailure(in: payload) {
                        if failure.code == GatewayErrorCode.unauthenticated.rawValue {
                            Log.info(Log.Module.gateway, "auth op refused: \(failure.code) — \(failure.message)")
                            throw GatewayClientError.unauthenticated
                        }
                        throw GatewayClientError.refused(failure)
                    }
                    throw GatewayClientError.unauthenticated
                }
                // 正常续期编排的第一环：debug 留痕，不打满 info。
                Log.debug(Log.Module.gateway, "401 on business op — refreshing ticket")
                return nil
            }
            if http.statusCode != 200 {
                Log.warn(Log.Module.gateway, "HTTP \(http.statusCode) from \(baseURL.host ?? "?")")
                throw GatewayClientError.badStatus(http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(Response.self, from: payload)
        } catch {
            // 解不出来时先看看能不能读出信封里的 error —— 服务端的拒绝
            // 比解码器的报错信息有用得多。
            if let failure = envelopeFailure(in: payload) {
                Log.warn(Log.Module.gateway, "op refused: \(failure.code) — \(failure.message)")
                throw GatewayClientError.refused(failure)
            }
            Log.warn(Log.Module.gateway, "malformed response: \(String(describing: error))")
            throw GatewayClientError.malformedResponse(detail: String(describing: error))
        }
    }
}

/// 只用来在解码失败时兜出信封里的错误。
private struct FailureEnvelope: Decodable {
    let error: GatewayFailure?
}

/// 信封里的 error（没有就 nil）。
private func envelopeFailure(in payload: Data) -> GatewayFailure? {
    (try? JSONDecoder().decode(FailureEnvelope.self, from: payload))?.error
}

/// 传输与信封读面的错误（R2 从 `GatewayClient` 搬入）：不是协议语义，是「这次请求
/// 卡在哪一层」的翻译。协议内的拒绝走 `.refused(GatewayFailure)`。
enum GatewayClientError: LocalizedError {
    /// 请求压根没发出去或没回来 —— 网络层的事，不是协议层的事。
    case transport(url: URL, underlying: Error)
    /// 回来了，但 HTTP 状态不是 200（协议下 400 = body 不是 JSON，413 = body 过大）。
    case badStatus(Int)
    /// 回来了、200，但不是我们能读的报文。
    case malformedResponse(detail: String)
    /// 响应的 `v` 不是本客户端认识的版本。
    case versionMismatch(Int)
    /// 服务端按信封拒绝了。这是**协议内的**结果，不是故障。
    case refused(GatewayFailure)
    /// 没有可用身份（M4）：未配对，或设备凭证已被服务端撤销。
    /// 不可重试 —— 重试要靠重新配对，不是再发一次。
    case unauthenticated

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
            return "请求超时（\(Int(GatewayTransport.timeout)) 秒）—— 地址可能写错了，或者中间有东西在丢包。"
        default:
            return "网络错误 \(urlError.code.rawValue)：\(urlError.localizedDescription)"
        }
    }
}

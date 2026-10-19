import Foundation

/// 对 Mac 网关的**纯传输层**：拼请求、发一次 `POST /rpc`、按 HTTP 状态与信封判成败、
/// 把 URLError 原样带在错误里（翻成人话在 `Display/FailureText.swift`）。
///
/// 切分判据 = 「改了要不要升协议版本」：这里的代码不碰协议语义 ——
/// 消息结构在 `GatewayProtocol.swift`，身份状态机（pair / 续期单飞 / `isPaired`）留在
/// `GatewayClient`，它调本类发送。
@MainActor
final class GatewayTransport {
    let baseURL: URL

    /// 承载请求的 session：默认 `shared`（局域网直连，行为不变）；
    /// 组网后注入 `TailnetNode.gatewaySession`（SOCKS5 回环 → tailnet），消息层零感知。
    private let session: URLSession

    /// 协议里的唯一端点 —— 所有 op 都打这一个地址，靠信封里的 `op` 分派。
    /// 多端点会把资源语义烧进 URL：客户端就得记住哪个资源走哪个地址，
    /// 而这件事协议已经从请求体里回答过了。
    nonisolated static let rpcPath = "/rpc"

    /// 请求超时。局域网直连正常是毫秒级，10 秒只用来兜住「地址写错」这种情况。
    nonisolated static let timeout: TimeInterval = 10

    /// 三张票在手机侧的家。默认共享单例：全 App 一个身份。
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
        // 身份只走传输头，不进消息体：消息体的每一个字段都是协议的一部分，
        // 凭证放进去会让它出现在日志、重放与错误回显里。
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

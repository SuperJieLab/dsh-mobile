/**
 * 一元调用的**裸发层**：发一次、读回包、判成败。**它不认识票。**
 *
 * 「带不带票」是调用方给不给 `authorization` —— 于是免票那条路（换票自己）结构上拿不到票，
 * 不可能回头去问票层（那是「等自己那一趟」的死锁）。只认识三件事：往哪打、一段字节、怎么算失败。
 */
import Foundation

@MainActor
final class HttpTransport {

    /// 这次走哪条传输。每次发请求现取 —— 组网换过传输之后下一发即生效。
    private let sessionProvider: () -> URLSession
    /// 往哪打。`nil` 表示隧道还没通 —— fail-fast，不猜地址。
    private let baseURLProvider: () -> URL?

    init(session: @escaping () -> URLSession, baseURL: @escaping () -> URL?) {
        self.sessionProvider = session
        self.baseURLProvider = baseURL
    }

    /// 唯一端点 —— 所有 op 都打这一个地址，靠信封里的 `op` 分派。
    nonisolated static let rpcPath = "/rpc"

    /// 请求超时。局域网直连正常是毫秒级，10 秒只用来兜住「地址写错」这种情况。
    nonisolated static let timeout: TimeInterval = 10

    /// 发一次，不解身份语义，并在解码后校验信封。
    ///
    /// 返回 `nil` 只表示**业务请求被 401 拒了**（换票再来一次的号）。配对与换票的 401 是
    /// **定论**，必须读出信封里的原因上抛：配对码不对就要说配对码不对。
    func send<Request: GatewayRequest, Response: GatewayResponse>(
        _ request: Request,
        requestId: String?,
        authorization: String?,
        treat401AsRefusal: Bool
    ) async throws -> Response? {
        guard let baseURL = baseURLProvider() else { throw RpcClientError.notActivated }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(Self.rpcPath))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 身份只走传输头，不进消息体：消息体的每一个字段都是协议的一部分，
        // 凭证放进去会让它出现在日志、重放与错误回显里。
        if let authorization {
            urlRequest.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        // 关联标记走头而不走消息体：它是传输层的事，不是协议形状的一部分 ——
        // 放进消息体就得改契约、也会让「同一件事有两个地方描述」。
        // 显式收参而不是在这里读 `RpcTrace.requestId`：让「这一发属于哪次请求」在签名上
        // 看得见，也让换票那条自造 id 的路径能决定带不带。
        if let requestId {
            urlRequest.setValue(requestId, forHTTPHeaderField: RpcTrace.headerName)
        }
        urlRequest.timeoutInterval = Self.timeout
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let payload: Data
        let urlResponse: URLResponse
        do {
            (payload, urlResponse) = try await sessionProvider().data(for: urlRequest)
        } catch {
            // 请求没发出去或没回来：读链路唯一的服务端外故障点，必须留痕。
            Log.warn(
                Log.Module.gateway,
                "transport: \(request.op) — \(error.localizedDescription) (base=\(baseURL.host ?? "?"))"
            )
            throw RpcClientError.transport(url: urlRequest.url ?? baseURL, underlying: error)
        }

        if let http = urlResponse as? HTTPURLResponse {
            guard http.statusCode != 401 else {
                // 业务请求的 401 是「换个票再来」的信号，返回 nil 交外层换票重试；鉴权请求
                // 的 401 自带语义，必须读出信封上抛。
                guard treat401AsRefusal else {
                    Log.debug(Log.Module.gateway, "401 on business op — renewing ticket")
                    return nil
                }
                if let failure = envelopeFailure(in: payload) {
                    if failure.code == GatewayErrorCode.unauthenticated.rawValue {
                        Log.info(
                            Log.Module.gateway,
                            "auth op refused: \(request.op) — \(failure.code) — \(failure.message)"
                        )
                        throw RpcClientError.unauthenticated
                    }
                    throw RpcClientError.refused(failure)
                }
                throw RpcClientError.unauthenticated
            }
            if http.statusCode != 200 {
                Log.warn(Log.Module.gateway,
                         "HTTP \(http.statusCode) on \(request.op) from \(baseURL.host ?? "?")")
                throw RpcClientError.badStatus(http.statusCode)
            }
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: payload)
        } catch {
            // 解不出来时先看看能不能读出信封里的 error —— 服务端的拒绝
            // 比解码器的报错信息有用得多。
            if let failure = envelopeFailure(in: payload) {
                Log.warn(Log.Module.gateway,
                         "\(request.op) refused: \(failure.code) — \(failure.message)")
                throw RpcClientError.refused(failure)
            }
            // 解不出来**且**报文声明的版本与我们不同 → 真正的原因是版本不一致，不是报文畸形。
            // 这两种的补救完全不同：一个要升级，一个要查代码。不先探这一眼的话，
            // 「网关升级了」会被报成「报文畸形」，人就去翻解码器了。
            if let version = versionProbe(in: payload), version != gatewayProtocolVersion {
                Log.warn(Log.Module.gateway,
                         "\(request.op) came back as protocol v\(version), we speak v\(gatewayProtocolVersion)")
                throw RpcClientError.versionMismatch(version)
            }
            Log.warn(Log.Module.gateway,
                     "\(request.op) returned a malformed response: \(String(describing: error))")
            throw RpcClientError.malformedResponse(detail: String(describing: error))
        }
        try response.validate()
        return response
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

/// 只用来在解码失败时读出信封声明的版本。
///
/// `v` 声明成可选：读不出就返回 `nil`，那时确实分不清是畸形还是版本不同，
/// 按畸形报 —— 不猜。
private struct VersionProbe: Decodable {
    let v: Int?
}

private func versionProbe(in payload: Data) -> Int? {
    (try? JSONDecoder().decode(VersionProbe.self, from: payload))?.v
}

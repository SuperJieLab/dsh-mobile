/**
 * 一元调用的**裸发层**：拼信封、发一次、拆信封、判成败。**它不认识票。**
 *
 * 「带不带票」是调用方给不给 `authorization` —— 于是免票那条路（换票自己）结构上拿不到票，
 * 不可能回头去问票层（那是「等自己那一趟」的死锁）。只认识三件事：往哪打、一段字节、怎么算失败。
 *
 * **信封只在这一层出现**：`{type, rpcId, method, payload:{args}}` 与
 * `{type, rpcId, result:{ok, value|error}}` 是「怎么出门」的知识，业务类型不该知道。
 * 这也是为什么 `RpcMessages.swift` 里的请求只有端点名与参数、应答只有业务字段。
 */
import Foundation

/// 客户端发出去的外壳。三格固定，加一格就是改协议。
private struct ClientEnvelope<Args: Encodable>: Encodable {
    let type = "client-request"
    let rpcId: String
    let method: String
    let payload: Payload

    struct Payload: Encodable {
        let args: Args
    }
}

/// 服务端回来的外壳。`ok` 与 `error` 住在这里 —— 业务类型不再各带一份。
private struct ServerEnvelope<Value: Decodable>: Decodable {
    struct Result: Decodable {
        let ok: Bool
        let value: Value?
        let error: GatewayFailure?
    }

    let type: String
    let rpcId: String
    let result: Result
}

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

    /// 请求超时。局域网直连正常是毫秒级，10 秒只用来兜住「地址写错」这种情况。
    nonisolated static let timeout: TimeInterval = 10

    /// 发一次，不解身份语义，并在拆信封时判成败。
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
        // 端点名既是路径也是信封里的 `method` —— 两处必须同值，网关会核这一致性。
        let endpoint = Request.endpoint
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/\(endpoint)"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 身份只走传输头，不进消息体：消息体的每一个字段都是协议的一部分，
        // 凭证放进去会让它出现在日志、重放与错误回显里。
        if let authorization {
            urlRequest.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        // 关联标记走头而不走消息体：它是传输层的事，不是协议形状的一部分。
        // 与体里的 `rpcId` 分工不同 —— 那个是应用层的「这次调用」，这个是传输层的追踪。
        if let requestId {
            urlRequest.setValue(requestId, forHTTPHeaderField: RpcTrace.headerName)
        }
        urlRequest.timeoutInterval = Self.timeout
        urlRequest.httpBody = try JSONEncoder().encode(
            ClientEnvelope(rpcId: requestId ?? "", method: endpoint, payload: .init(args: request))
        )

        let payload: Data
        let urlResponse: URLResponse
        do {
            (payload, urlResponse) = try await sessionProvider().data(for: urlRequest)
        } catch {
            // 请求没发出去或没回来：读链路唯一的服务端外故障点，必须留痕。
            // 打完整 URL 而不只是主机名 —— `-1000 bad URL` 这类病因只在 scheme 与端口上，
            // 只记主机名会让「地址拼错」与「网络不通」在日志里长得一模一样。
            // `via` 说明这一发走的是隧道代理还是直连：隧道里的 SOCKS 拒绝建连时，
            // CFNetwork 报的同样是 -1000，没有这一格就分不清它到底出在哪一段。
            Log.warn(
                Log.Module.gateway,
                "transport failed",
                ["op": endpoint, "error": error.localizedDescription,
                 "url": (urlRequest.url ?? baseURL).absoluteString,
                 "via": sessionProvider().configuration.proxyConfigurations.isEmpty
                     ? "direct" : "proxy"]
            )
            throw RpcClientError.transport(url: urlRequest.url ?? baseURL, underlying: error)
        }

        if let http = urlResponse as? HTTPURLResponse {
            guard http.statusCode != 401 else {
                // 业务请求的 401 是「换个票再来」的信号，返回 nil 交外层换票重试；鉴权请求
                // 的 401 自带语义，必须读出信封上抛。
                guard treat401AsRefusal else {
                    Log.debug(Log.Module.gateway, "401 on business endpoint — renewing ticket")
                    return nil
                }
                if let failure = envelopeFailure(in: payload) {
                    if failure.code == GatewayErrorCode.unauthenticated.rawValue {
                        Log.info(
                            Log.Module.gateway,
                            "auth endpoint refused",
                            ["op": endpoint, "code": failure.code, "reason": failure.message]
                        )
                        throw RpcClientError.unauthenticated
                    }
                    throw RpcClientError.refused(failure)
                }
                throw RpcClientError.unauthenticated
            }
            if http.statusCode != 200 {
                Log.warn(Log.Module.gateway, "bad status",
                         ["code": String(http.statusCode), "op": endpoint,
                          "url": (urlRequest.url ?? baseURL).absoluteString])
                throw RpcClientError.badStatus(http.statusCode)
            }
        }

        let envelope: ServerEnvelope<Response>
        do {
            envelope = try JSONDecoder().decode(ServerEnvelope<Response>.self, from: payload)
        } catch {
            // 解不出来时先看看能不能读出信封里的 error —— 服务端的拒绝
            // 比解码器的报错信息有用得多。
            if let failure = envelopeFailure(in: payload) {
                Log.warn(Log.Module.gateway, "refused",
                         ["op": endpoint, "code": failure.code, "reason": failure.message])
                throw RpcClientError.refused(failure)
            }
            Log.warn(Log.Module.gateway, "malformed response",
                     ["op": endpoint, "error": String(describing: error)])
            throw RpcClientError.malformedResponse(detail: String(describing: error))
        }

        guard envelope.result.ok else {
            throw RpcClientError.refused(
                envelope.result.error
                    ?? GatewayFailure(code: GatewayErrorCode.internalError.rawValue, message: "", details: [:])
            )
        }
        if let value = envelope.result.value { return value }
        // `ok: true` 而 `value` 整格缺席：协议上说「没有内容可回」时给 `{}`，
        // 所以按空对象再解一次。全可选的应答类型解得开，其余在这里暴露成畸形。
        guard let empty = try? JSONDecoder().decode(Response.self, from: Data("{}".utf8)) else {
            throw RpcClientError.malformedResponse(detail: "\(endpoint): ok without a value")
        }
        return empty
    }
}

/// 只用来在解码失败时兜出信封里的错误。
private struct FailureEnvelope: Decodable {
    struct Result: Decodable {
        let error: GatewayFailure?
    }

    let result: Result?
}

/// 信封里的 error（没有就 nil）。
private func envelopeFailure(in payload: Data) -> GatewayFailure? {
    (try? JSONDecoder().decode(FailureEnvelope.self, from: payload))?.result?.error
}

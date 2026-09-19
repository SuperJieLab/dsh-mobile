import Foundation

/// 与 Mac 侧网关切口的**唯一**接触点。
///
/// 它只做三件事：拼请求信封、发一次 `POST /rpc`、按信封判成败。
/// 协议的类型与语义都在 `GatewayProtocol.swift` 里，SwiftUI 在这里没有位置 ——
/// 这与 Mac 侧把协议写成纯函数 `handle(msg)` 是同一个手法：
/// 协议处理不该和它的使用者缠在一起。
struct GatewayClient {
    let baseURL: URL

    /// 协议里的唯一端点。多端点会把资源语义烧进 URL（见 `docs/protocol.md` §二）。
    static let rpcPath = "/rpc"

    /// 请求超时。局域网直连正常是毫秒级，10 秒只用来兜住「地址写错」这种情况。
    static let timeout: TimeInterval = 10

    // MARK: - 三个 op

    /// 拉会话列表。服务端已按 `updatedAt` 降序排好 —— 协议规定客户端**不必自己排**。
    func listSessions() async throws -> [SessionSummary] {
        let response: ListSessionsResponse = try await send(ListSessionsRequest())
        try response.validate()
        return response.sessions ?? []
    }

    /// 拉某会话的快照。
    /// - Parameter since: 客户端**下一个期望的 seq** —— 由本地镜像记着，不是每次传 0。
    func snapshot(sessionId: String, since: Int = 0) async throws -> SessionSnapshot {
        let response: SnapshotResponse = try await send(
            SnapshotRequest(sessionId: sessionId, since: since)
        )
        try response.validate()
        // `ok: true` 却没有载荷是服务端的错，不该被默认值悄悄盖过去。
        guard let asOfSeq = response.asOfSeq, let events = response.events else {
            throw GatewayClientError.malformedResponse(detail: "ok: true，但响应里没有 asOfSeq / events")
        }
        return SessionSnapshot(
            sessionId: response.sessionId ?? sessionId,
            asOfSeq: asOfSeq,
            // 缺省 `false`：不带这个字段的是旧服务端，它只会一次给完（协议 §五）。
            hasMore: response.hasMore ?? false,
            events: events
        )
    }

    /// 拉一段回溯窗口 —— 打开会话与往回翻都用它。
    /// - Parameters:
    ///   - beforeSeq: 窗口上界（不含）。不传表示「从最新往回」，即打开会话；
    ///     往回翻时传上一次的 `pageStart`。
    ///   - maxMessages: 最多取多少条消息。不传就用服务端的默认值。
    func page(sessionId: String, beforeSeq: Int? = nil, maxMessages: Int? = nil) async throws -> SessionPage {
        let response: PageResponse = try await send(
            PageRequest(sessionId: sessionId, beforeSeq: beforeSeq, maxMessages: maxMessages)
        )
        try response.validate()
        // `ok: true` 却没有载荷是服务端的错，不该被默认值悄悄盖过去。
        guard let pageStart = response.pageStart,
              let asOfSeq = response.asOfSeq,
              let hasOlder = response.hasOlder,
              let events = response.events else {
            throw GatewayClientError.malformedResponse(detail: "ok: true，但响应里缺少 pageStart / asOfSeq / hasOlder / events")
        }
        return SessionPage(
            sessionId: response.sessionId ?? sessionId,
            pageStart: pageStart,
            asOfSeq: asOfSeq,
            hasOlder: hasOlder,
            events: events
        )
    }

    // MARK: - 发一次请求

    private func send<Request: Encodable, Response: Decodable>(
        _ request: Request,
        as: Response.Type = Response.self
    ) async throws -> Response {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(Self.rpcPath))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = Self.timeout
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let payload: Data
        let urlResponse: URLResponse
        do {
            (payload, urlResponse) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw GatewayClientError.transport(url: urlRequest.url ?? baseURL, underlying: error)
        }

        if let http = urlResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw GatewayClientError.badStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: payload)
        } catch {
            // 解不出来时先看看能不能读出信封里的 error —— 服务端的拒绝
            // 比解码器的报错信息有用得多。
            if let envelope = try? JSONDecoder().decode(FailureEnvelope.self, from: payload),
               let failure = envelope.error {
                throw GatewayClientError.refused(failure)
            }
            throw GatewayClientError.malformedResponse(detail: String(describing: error))
        }
    }
}

// MARK: - 地址

extension GatewayClient {
    /// Mac 网关的地址 —— **全 App 唯一需要改的一行**。
    ///
    /// M0 的取舍就是硬编码（Plan §4.3 Step 4）：不做设备发现、不做配置界面。
    /// 换成 `http://<Mac的主机名>.local:3081` 也行，那条路走 mDNS，IP 变了不用改。
    static let defaultBaseURL = URL(string: "http://192.168.125.23:3081")!
}

// MARK: - 请求

private struct ListSessionsRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "list-sessions"
}

private struct SnapshotRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "snapshot"
    let sessionId: String
    let since: Int
}

/// 可选字段为 `nil` 时不会出现在 JSON 里（合成实现用的是 `encodeIfPresent`），
/// 这正是协议要的形状：不传 `beforeSeq` 的意思是「从最新往回」，而不是「空值」。
private struct PageRequest: Encodable {
    let v = gatewayProtocolVersion
    let op = "page"
    let sessionId: String
    let beforeSeq: Int?
    let maxMessages: Int?
}

// MARK: - 响应

/// 响应信封的公共部分（协议 §三）。
///
/// 载荷字段一律声明成可选：服务端拒绝时（`ok: false`）根本不会带载荷，
/// 若声明成必选，解码会先一步失败，我们就拿不到那条有用的 `error` 了。
protocol GatewayResponse: Decodable {
    var v: Int { get }
    var ok: Bool { get }
    var error: GatewayFailure? { get }
}

extension GatewayResponse {
    func validate() throws {
        guard v == gatewayProtocolVersion else {
            throw GatewayClientError.versionMismatch(v)
        }
        guard ok else {
            throw GatewayClientError.refused(
                error ?? GatewayFailure(code: "internal-error", message: "服务端拒绝了请求，但没带 error")
            )
        }
    }
}

private struct ListSessionsResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let serverTime: Double?
    let sessions: [SessionSummary]?
}

private struct SnapshotResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let sessionId: String?
    let asOfSeq: Int?
    let hasMore: Bool?
    let events: [SessionEvent]?
}

private struct PageResponse: GatewayResponse {
    let v: Int
    let ok: Bool
    let error: GatewayFailure?
    let sessionId: String?
    let pageStart: Int?
    let asOfSeq: Int?
    let hasOlder: Bool?
    let events: [SessionEvent]?
}

/// 只用来在解码失败时兜出信封里的错误。
private struct FailureEnvelope: Decodable {
    let error: GatewayFailure?
}

// MARK: - 快照

/// 一次快照的结果。
struct SessionSnapshot {
    let sessionId: String
    /// 本次覆盖到的位置（不含）—— 回传它就能拿到「空增量」，是水位不变式的用法。
    let asOfSeq: Int
    /// 服务端是否还有没给完的事件。为真就接着要 —— 单次响应有上限（协议 §五）。
    let hasMore: Bool
    let events: [SessionEvent]

    /// 能显示成消息的事件。其余事件（工具调用、轮次边界、用量……）不属于对话内容。
    var messages: [DisplayMessage] { events.compactMap(\.displayMessage) }
}

// MARK: - 回溯窗口

/// 一段往回读的窗口（协议 §4.3）。
///
/// 与 `SessionSnapshot` 是两个方向：快照从 `since` 往后走，窗口从某个位置往回走。
/// 打开会话时用后者取最近一段，之后用前者追新增 —— 这样客户端**不需要跨会话
/// 记住任何位置**，冷启动永远从「现在的最新一段」开始。
struct SessionPage {
    let sessionId: String
    /// 窗口首个事件的 `seq` —— 即下一次往回翻时的 `beforeSeq`。
    let pageStart: Int
    /// 窗口末尾（不含）。与 `SessionSnapshot.asOfSeq` 同义。
    let asOfSeq: Int
    /// 窗口之前还有事件吗。`false` 表示已经到日志开头。
    let hasOlder: Bool
    let events: [SessionEvent]
}

// MARK: - 失败

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
        }
    }

    /// 把 `URLError` 翻译成人话 —— **Step 4 真正要撞的两个坑会在这里自己报出名字**。
    ///
    /// iOS 上有两套彼此独立的管控会拦掉到局域网的明文 HTTP，各自报不同的错：
    /// ATS 报 `-1200`，LNP 报 `NotConnectedToInternet`。改错地方都白改，
    /// 所以这里必须把它们分开说。
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
            return "请求超时（\(Int(GatewayClient.timeout)) 秒）—— 地址可能写错了，或者中间有东西在丢包。"
        default:
            return "网络错误 \(urlError.code.rawValue)：\(urlError.localizedDescription)"
        }
    }
}

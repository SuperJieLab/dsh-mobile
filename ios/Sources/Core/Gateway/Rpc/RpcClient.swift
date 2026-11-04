import Foundation

/// 与 Mac 侧网关的**请求门面**：带票发一次，并维护票的生命周期。它**不认识任何 op**。
/// 身份不在这里（真值是 `CredentialStore.deviceToken`）；发字节那半在 `HttpTransport`。
@MainActor
final class RpcClient {

    /// 往哪打：组网域产出的地址，本类只**问**它，不存副本。`nil` = 隧道没通。
    private let baseURLProvider: () -> URL?
    /// 裸发层 —— 票闸在下面，它不认识票。
    private let http: HttpTransport

    private let credentials: CredentialStore

    /// 写操作的审计落点。`nil` = 不记（判据与只读场景不需要它）。
    private let audit: AuditLog?

    /// 票的生命周期。换票动作在本类 —— 它要线路与协议，票那一层不该认识。
    /// **必须 `lazy`**：构造它要一个读 `self.renewTicket` 的闭包，而那要求所有存储属性已初始化。
    private(set) lazy var tickets = TicketKeeper { [weak self] deviceToken in
        guard let self else { return .retryLater }
        return await self.renewTicket(deviceToken: deviceToken)
    }

    init(session: @escaping () -> URLSession,
         baseURL: @escaping () -> URL?,
         credentials: CredentialStore? = nil,
         audit: AuditLog? = nil) {
        // nil 默认值是为了避开跨 actor 的默认表达式求值。
        self.baseURLProvider = baseURL
        self.http = HttpTransport(session: session, baseURL: baseURL)
        self.credentials = credentials ?? .shared
        self.audit = audit
    }

    // MARK: - 关系结束

    /// **关系结束了**：本机不再持有这张凭证，手上的票也一并作废。
    /// 两半必须一起做：只删凭证不清票会留下「有票没凭证」的窗口，请求照常成功而用户以为关系已解除。
    /// 两半分别住在 `CredentialStore` 与 `TicketKeeper`，只有本类同时持有。
    func discardIdentity(reason: Reason) {
        Log.warn(Log.Module.gateway, "identity discarded, token and ticket cleared",
                 ["reason": reason.logWord])
        credentials.deleteDeviceToken()
        tickets.clear()
    }

    enum Reason {
        case revokedByServer
        case userRequested

        var logWord: String {
            switch self {
            case .revokedByServer: return "by server"
            case .userRequested: return "by user"
            }
        }
    }

    // MARK: - 票

    /// 换一张票：有就立刻给，没有就去换（并发搭同一趟）。
    /// 凭证按参传入，不让票层自己取：它是纯状态机，输入只有换票动作与这一枚凭证。
    /// 只有这个方法留在本类 —— 换票是**组合**；只读现状直接用 `tickets.validToken()`。
    func ticket() async -> AccessTicket {
        await tickets.ticket(deviceToken: credentials.deviceToken)
    }

    /// 换票动作本身。**直接走裸发层，不走 `perform`** —— 后者会先问票层要票，
    /// 而票层正等在这次换票上。
    private func renewTicket(deviceToken: String) async -> TicketKeeper.Renewal {
        do {
            let response: RefreshResponse? = try await http.send(
                RefreshRequest(deviceToken: deviceToken),
                // 换票不走 `perform`（票层正等在这次换票上），所以这里自己铸一个 ——
                // 换票的两行仍然能归到一起，只是与触发它的那次业务请求对不上。
                requestId: RpcTrace.newId(),
                authorization: nil,
                treat401AsRefusal: true
            )
            guard let response else {
                // 鉴权请求的 401 在裸发层里自带语义上抛，不会返回 nil —— 真到了这里说明
                // 有人在裸发层改了那条分支。按「换不到」处理，不静默。
                Log.warn(Log.Module.gateway, "refresh returned without a verdict")
                return .retryLater
            }
            guard let token = response.accessToken, let expiresAt = response.expiresAt else {
                // `ok: true` 却没带票：服务端的应答有问题，下一轮还会是同一个答案。
                Log.warn(Log.Module.gateway, "refresh answered without a ticket")
                return .retryLater
            }
            // 服务端每次续期都轮换设备凭证：**先存新的，再交票**。存不下就别往下走 ——
            // 手里那张票只活 15 分钟，而凭证丢了要重新配对。
            if let rotated = response.deviceToken {
                credentials.saveDeviceToken(rotated)
            }
            Log.debug(Log.Module.session, "access ticket renewed")
            return .issued(
                .init(token: token, expiresAt: epochMilliseconds(expiresAt))
            )
        } catch RpcClientError.unauthenticated {
            // 服务端不认这段关系了：撤销或凭证被替换。重试没有意义。
            discardIdentity(reason: .revokedByServer)
            return .unavailable
        } catch {
            // 传输失败不是关系终结：票换不到只是暂时，退避后再试。
            Log.warn(Log.Module.session, "ticket renewal failed (transport) — will retry")
            return .retryLater
        }
    }

    // MARK: - 发一次请求

    /// 唯一的出网入口：带上票发一次，被 401 拒了就换票再试恰好一次。
    /// 回包已过 `validate()` —— **这条校验只写在这里**：op 散到各功能后，少写一次既不报错
    /// 也不变红。
    /// - Parameter authenticated: 要不要票，**配对是唯一的 `false`**；401 该怎么读也由它定。
    func perform<Request: GatewayRequest, Response: GatewayResponse>(
        _ request: Request,
        authenticated: Bool = true
    ) async throws -> Response {
        // 每个 op 一次标记：网关把同一次请求产生的每一行都冠上它，客户端的行也带着 ——
        // 两端因此能按同一个 id 对上。401 换票后的重试沿用同一个 id（那是同一次操作）。
        try await RpcTrace.withNewId { requestId in
            do {
                let response: Response = try await sendOnce(
                    request, requestId: requestId, authenticated: authenticated
                )
                record(request, result: .ok, requestId: requestId)
                return response
            } catch {
                // 失败也记：审计要回答「谁试过改什么」，只记成功的会让「为什么没改成」
                // 永远只有日志那一份线索。
                record(request, result: .refused(code: Self.auditCode(of: error)),
                       requestId: requestId)
                throw error
            }
        }
    }

    /// 记一条审计。**只有写请求会被记** —— 判断靠 `AuditableRequest`，不靠 op 名单。
    private func record<Request: GatewayRequest>(
        _ request: Request,
        result: AuditResult,
        requestId: String
    ) {
        guard let auditable = request as? AuditableRequest else { return }
        audit?.record(AuditEntry(
            at: Date(),
            op: request.op,
            target: auditable.auditTarget,
            result: result,
            requestId: requestId
        ))
    }

    /// 失败折成审计里的一个码。协议内的拒绝用自己的码（与网关那侧一致），其余用 case 名 ——
    /// 它们本来不是同一个词汇表，混成一个会让人去查一个不存在的错误码。
    private static func auditCode(of error: Error) -> String {
        (error as? RpcClientError)?.auditCode ?? "unknown"
    }

    private func sendOnce<Request: GatewayRequest, Response: GatewayResponse>(
        _ request: Request,
        requestId: String,
        authenticated: Bool
    ) async throws -> Response {
        // 隧道没通 = 没有地址可打：fail-fast，不猜地址。
        guard let baseURL = baseURLProvider() else { throw RpcClientError.notActivated }
        // 先换再发：票还在（15 分钟内）时一次都不等，没票时才付那一次 wait —— 比「先发
        // 一发注定被拒的」少一半往返。
        let ticket = authenticated ? await self.ticket() : nil
        // 标注类型：`send` 的返回只在这里判空，编译器无从推它的泛型参数。
        let first: Response? = try await http.send(
            request, requestId: requestId, authorization: ticket?.token,
            treat401AsRefusal: !authenticated
        )
        if let first { return first }
        // 走到这里 = 业务请求被 401 拒了。换一张票（单飞），恰好重试一次。
        // 换不到时按处境说不同的话：`.unavailable` 与 `.retryLater` 说反了，
        // 用户会去查一件没发生的事。
        guard authenticated else { throw RpcClientError.unauthenticated }
        // 调 `renewAnyway` 而不是 `ticket()`：本地那张被服务端否认了，
        // 读缓存只会把同一枚死票再发一遍。
        switch await tickets.renewAnyway(deviceToken: credentials.deviceToken) {
        case .granted(let fresh):
            // 同一个 id：换票重试仍是同一次操作。
            let retried: Response? = try await http.send(
                request, requestId: requestId, authorization: fresh, treat401AsRefusal: false
            )
            if let retried { return retried }
            throw RpcClientError.unauthenticated
        case .unavailable:
            throw RpcClientError.unauthenticated
        case .retryLater:
            throw RpcClientError.transport(url: baseURL, underlying: TicketUnavailable())
        }
    }

}

/// 换票没成（网络不通 / 网关不在）—— 只用来给「这次失败不是因为身份」一个可读的说法。
private struct TicketUnavailable: LocalizedError {
    var errorDescription: String? { "换取访问票失败 —— 网关没连上。" }
}


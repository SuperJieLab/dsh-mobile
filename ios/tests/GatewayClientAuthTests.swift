/**
 * 首次进入（或票过期后回来）不该先发一发注定被拒的请求。
 *
 * 这条判据盯的是**顺序**，不是结果：结果在两种写法下都是成功的（反应式会 401 → 续期 →
 * 重试成功），只有「第一发业务请求上有没有票」能分开它们。所以桩记录的是**收到的请求序列**，
 * 断言第一条业务请求已带 `Bearer`，且 `refresh` 排在它之前。
 *
 * 用真 `URLSession` + `URLProtocol` 桩，而不是给 `GatewayClient` 开一个口子：被测的正是
 * 「它自己怎么用传输」，替身放在传输边界之外才不预设答案。
 */
import Foundation
import XCTest

@testable import DshMobile

/// 按剧本回放的传输。剧本按 `op` 认领应答；没写到的 op 一律回 `internal-error`（看得见）。
final class ScriptedURLProtocol: URLProtocol {

    /// 一次应答：状态码 + JSON 体。
    struct Reply {
        let status: Int
        let body: String
    }

    /// op 名 → 应答。**按 `op` 而不是按到达顺序**：断言的落点是「哪一发带了票」，
    /// 用顺序发牌会把「多了一发」与「顺序错了」混成同一个失败。
    static var replies: [String: Reply] = [:]
    /// 非空时，每条请求都在传输层失败 —— 「网关没连上」的确定性替身。
    /// 不靠「127.0.0.1 上没人听」来造这个失败：那取决于本机此刻有没有跑着网关。
    static var transportFailure: URLError?
    /// 收到的请求（时间序），每条带 op 与 authorization 头。
    static var calls: [(op: String, authorization: String?)] = []
    /// 收到的请求体，按 op 归组（时间序）。断言载荷用 —— 只记 op 与票的话，
    /// 「decision 写反」「幂等键没透传」这类错法一条都看不出来。
    static var bodies: [String: [[String: Any]]] = [:]
    private static let lock = NSLock()

    static func reset(replies: [String: Reply]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        self.transportFailure = nil
        calls = []
        bodies = [:]
    }

    static func snapshot() -> [(op: String, authorization: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let transportFailure = Self.transportFailure {
            client?.urlProtocol(self, didFailWithError: transportFailure)
            return
        }
        // `URLProtocol` 拿到的 `httpBody` 是空的 —— 请求体在 `httpBodyStream` 里，只能从流读。
        let body = request.httpBody ?? Self.bodyStream(of: request)
        let parsed = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let op = parsed.flatMap { $0["op"] as? String } ?? "?"

        let reply = Self.claim(
            op: op, authorization: request.value(forHTTPHeaderField: "Authorization"), body: parsed
        )
        let payload = Data(reply.body.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1/")!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func claim(op: String, authorization: String?, body: [String: Any]?) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        calls.append((op, authorization))
        if let body { bodies[op, default: []].append(body) }
        return replies[op] ?? Reply(
            status: 200,
            body: #"{"v":2,"ok":false,"error":{"code":"internal-error","message":"no reply scripted for \#(op)"}}"#
        )
    }

    private static func bodyStream(of request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data.isEmpty ? nil : data
    }
}

@MainActor
final class GatewayClientAuthTests: XCTestCase {

    /// 一句续期应答。抽成构造器是为了让断言那一屏读得下去 —— 内联的 JSON 有 120 列。
    private static func ticket(_ token: String, expiresAt: Double = 9_999_999_999_999) -> ScriptedURLProtocol.Reply {
        .init(status: 200,
              body: #"{"v":2,"ok":true,"accessToken":"\#(token)","expiresAt":\#(expiresAt)}"#)
    }

    /// 一句空的会话列表应答：这几条用例只关心票的顺序，列表内容无所谓。
    private static let noSessions = ScriptedURLProtocol.Reply(
        status: 200, body: #"{"v":2,"ok":true,"sessions":[],"serverTime":0}"#
    )

    private static func script(ticket: ScriptedURLProtocol.Reply) {
        ScriptedURLProtocol.reset(replies: ["refresh": ticket, "list-sessions": noSessions])
    }

    override func setUp() {
        super.setUp()
        Self.script(ticket: Self.ticket("fresh"))
    }

    /// 一个已配对、但内存里没有票的客户端 —— 冷启动与「离开 15 分钟以上再回来」是同一个处境。
    /// 存储走内存：测试不该写进 App 真正的凭证目录。
    /// 走桩的 session —— 不碰真网络。
    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client() -> GatewayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        var stored: String? = "device-token"
        let store = CredentialStore(storage: .init(
            read: { stored },
            write: { stored = $0 },
            delete: { stored = nil }
        ))
        let client = GatewayClient(credentials: store)
        client.activate(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "http://127.0.0.1:3081")!
        )
        return client
    }

    /// 第一条业务请求就带票：`refresh` 排在它之前，且没有「先发一发无票的」。
    func testTheFirstBusinessRequestAlreadyCarriesATicket() async throws {
        let client = client()
        _ = try await fetchSessions(client)

        let calls = ScriptedURLProtocol.snapshot()
        XCTAssertEqual(calls.map(\.op), ["refresh", "list-sessions"],
                       "顺序是先换票、再发业务请求：\(calls.map(\.op))")
        XCTAssertEqual(calls[1].authorization, "Bearer fresh",
                       "业务请求上必须已经带上刚换到的票")
    }

    /// 手上有票时**一次都不换** —— 「先确认」不能变成「每次都换」。
    func testAValidTicketIsReusedWithoutRefreshing() async throws {
        let client = client()
        _ = try await fetchSessions(client)
        Self.script(ticket: Self.ticket("second"))
        _ = try await fetchSessions(client)

        XCTAssertEqual(ScriptedURLProtocol.snapshot().map(\.op), ["list-sessions"],
                       "票还在就不该再换一张")
    }

    /// 票真的过期了（`expiresAt` 在过去）→ 与没有票同一条路：先换再发。
    func testAnExpiredTicketIsRenewedBeforeSending() async throws {
        Self.script(ticket: Self.ticket("first", expiresAt: 1))
        let client = client()
        _ = try await fetchSessions(client) // 换到一张早就过期的票
        Self.script(ticket: Self.ticket("second"))
        _ = try await fetchSessions(client)

        let calls = ScriptedURLProtocol.snapshot()
        XCTAssertEqual(calls.map(\.op), ["refresh", "list-sessions"],
                       "过期的票等价于没有票")
        XCTAssertEqual(calls[1].authorization, "Bearer second")
    }

    // MARK: - 三种处境（`AccessTicket`）

    /// 未配对 → `.unavailable`：**不会自己好**，调用方该停而不是等。
    func testWithoutAPairedDeviceTheAnswerIsUnavailable() async {
        // 存储是空的内存盒：没有设备凭证。
        var stored: String?
        let store = CredentialStore(storage: .init(
            read: { stored }, write: { stored = $0 }, delete: { stored = nil }
        ))
        let client = GatewayClient(credentials: store)
        client.activate(
            session: Self.stubbedSession(),
            baseURL: URL(string: "http://127.0.0.1:3081")!
        )

        let outcome = await client.ticket()
        XCTAssertEqual(outcome, .unavailable, "没有设备凭证 → 换不出票，且重试没有意义")
        XCTAssertTrue(ScriptedURLProtocol.snapshot().isEmpty, "连 refresh 都不该发 —— 本来就没有可换的东西")
    }

    /// 换票撞上传输失败 → `.retryLater`，**不是** `.unavailable`。
    ///
    /// 这一条守的是「别把网络问题说成身份问题」：两者在界面上是完全不同的两句话，
    /// 而后者会让人去重新配对一件没坏的事。
    func testATransportFailureWhileRenewingIsRetryableNotUnavailable() async {
        var stored: String? = "device-token"
        let store = CredentialStore(storage: .init(
            read: { stored }, write: { stored = $0 }, delete: { stored = nil }
        ))
        let client = GatewayClient(credentials: store)
        client.activate(
            session: Self.stubbedSession(),
            baseURL: URL(string: "http://127.0.0.1:3081")!
        )
        ScriptedURLProtocol.transportFailure = URLError(.cannotConnectToHost)

        let outcome = await client.ticket()
        XCTAssertEqual(outcome, .retryLater, "换不到只是这一次，不是关系没了")
        XCTAssertEqual(stored, "device-token", "传输失败绝不能清掉设备凭证 —— 那是关系的本体")
        XCTAssertTrue(client.isPaired, "关系仍在")
    }
}

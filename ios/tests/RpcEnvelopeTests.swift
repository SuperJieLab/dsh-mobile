/**
 * 一元的信封（判据 6、7）。
 *
 * 三条各守一个失败方式：
 * - 请求的**路径末两段与体内的 `method` 相同**。网关会核这一致性，不一致直接
 *   `invalid-request` —— 客户端自己先对不上，等于每次调用都注定被拒。
 * - 体里**没有 `v`、没有 `op`**。这两格退役了，残留说明「只改了一半」。
 * - 失败信封的 `details` 能解出来；**缺它时补空字典而不是让整条应答失败** ——
 *   把一条可读的拒绝退化成「报文畸形」，排障时看到的是解码器的报错而不是服务端的话。
 *
 * Run: 设备或模拟器上的 XCTest target（本仓库的 `ios/tests/`）。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class RpcEnvelopeTests: XCTestCase {

    private var configuration: URLSessionConfiguration!
    private var session: URLSession!
    private var baseURL: URL!

    override func setUp() {
        super.setUp()
        configuration = .ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        session = URLSession(configuration: configuration)
        baseURL = URL(string: "http://127.0.0.1:9")!
    }

    override func tearDown() {
        session.invalidateAndCancel()
        super.tearDown()
    }

    /// 不带票的客户端：这几条判据只看信封的形状，与身份无关。
    private func client() -> RpcClient {
        RpcClient(
            session: { [unowned self] in self.session },
            baseURL: { [unowned self] in self.baseURL },
            audit: nil
        )
    }

    /// 判据 6：路径与 `method` 同值，体里只有信封的四格加 `payload.args`。
    func testTheRequestCarriesTheEndpointInPathAndEnvelope() async throws {
        ScriptedURLProtocol.reset(replies: [
            "mobile/listSessions": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"sessions":[],"serverTime":0}}}"#
            ),
        ])

        _ = try await client().perform(ListSessionsRequest(), authenticated: false)

        let sent = try XCTUnwrap(ScriptedURLProtocol.bodies["mobile/listSessions"],
                                 "这一发没到达 mobile/listSessions —— 先看路径")
        let body = try XCTUnwrap(sent.first, "没有收到请求体")

        XCTAssertEqual(Set(body.keys), ["type", "rpcId", "method", "payload"],
                       "体顶层恰好四格 —— 多一格（比如残留的 v）说明只改了一半")
        XCTAssertEqual(body["type"] as? String, "client-request")
        XCTAssertEqual(body["method"] as? String, "mobile/listSessions",
                       "信封里的 method 必须与路径末两段相同")

        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["args"], "payload 只许一格 args")
    }

    /// 判据 7 的前半：`details` 要原样解出来。
    func testRefusalCarriesDetails() async throws {
        ScriptedURLProtocol.reset(replies: [
            "mobile/listSessions": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"invalid-request","message":"bad","details":{"field":"workspaceId"}}}}"#
            ),
        ])

        do {
            _ = try await client().perform(ListSessionsRequest(), authenticated: false)
            XCTFail("被拒的请求不该返回应答")
        } catch let RpcClientError.refused(failure) {
            XCTAssertEqual(failure.code, "invalid-request")
            XCTAssertEqual(failure.details["field"], .string("workspaceId"),
                           "details 是排障的唯一结构化信息，不能被静默丢掉")
        }
    }

    /// 判据 7 的后半：缺 `details` 时补空字典，而不是把整条拒绝变成「报文畸形」。
    func testRefusalWithoutDetailsStillReads() async throws {
        ScriptedURLProtocol.reset(replies: [
            "mobile/listSessions": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"unknown-session","message":"gone"}}}"#
            ),
        ])

        do {
            _ = try await client().perform(ListSessionsRequest(), authenticated: false)
            XCTFail("被拒的请求不该返回应答")
        } catch let RpcClientError.refused(failure) {
            XCTAssertEqual(failure.code, "unknown-session",
                           "缺 details 不该让 code 一起丢掉")
            XCTAssertEqual(failure.details, [:])
        } catch {
            XCTFail("缺 details 仍是可读的拒绝，不该报 \(error)")
        }
    }
}

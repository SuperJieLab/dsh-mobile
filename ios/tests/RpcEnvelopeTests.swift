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
            "session/list": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"items":[]}}}"#
            ),
        ])

        let _: ListSessionsResponse = try await client().perform(ListSessionsRequest(), authenticated: false)

        let sent = try XCTUnwrap(ScriptedURLProtocol.bodies["session/list"],
                                 "这一发没到达 session/list —— 先看路径")
        let body = try XCTUnwrap(sent.first, "没有收到请求体")

        XCTAssertEqual(Set(body.keys), ["type", "rpcId", "method", "payload"],
                       "体顶层恰好四格 —— 多一格（比如残留的 v）说明只改了一半")
        XCTAssertEqual(body["type"] as? String, "client-request")
        XCTAssertEqual(body["method"] as? String, "session/list",
                       "信封里的 method 必须与路径末两段相同")

        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["args"], "payload 只许一格 args")

        // S2：args 的键是**宿主的参数名**，不是我们起的容器名。
        let args = try XCTUnwrap(payload["args"] as? [String: Any])
        XCTAssertEqual(Set(args.keys), ["_request"], "session/list 的参数在 `_request` 里，照抄宿主的参数名")
        XCTAssertEqual((args["_request"] as? [String: Any])?.isEmpty, true, "本客户端做全量读，不带 cursor")
    }

    /// 判据 7：分页请求的容器名与水位。
    ///
    /// - 容器是 `request`（宿主的形参名），里面四组水位 + 窗口；
    /// - `throughSeq` 是**含端**的切点，`beforeSeq` 是**排他**的下界 —— 两个都发，各管一件事；
    /// - 窗口参数与打开会话那一组是同一份（`HistoryWindow.standard`），不是各写一遍。
    func testThePageRequestPinsTheCutUnderTheHostsContainerName() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/page": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"records":[],"cursor":12,"hasMore":false}}}"#
            ),
        ])

        let page = try await readPage(client(), sessionId: "s-1", throughSeq: 12, beforeSeq: 5)
        XCTAssertEqual(page.cursor, 12, "含端切点原样回来")
        XCTAssertFalse(page.hasMore)
        XCTAssertTrue(page.records.isEmpty)

        let sent = try XCTUnwrap(ScriptedURLProtocol.bodies["session/page"], "这一发没到达 session/page")
        let body = try XCTUnwrap(sent.first, "没有收到请求体")
        XCTAssertEqual(body["method"] as? String, "session/page")
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        let args = try XCTUnwrap(payload["args"] as? [String: Any])
        XCTAssertEqual(Set(args.keys), ["request"], "参数在 `request` 里 —— 少一层就是 invalid-request")

        let request = try XCTUnwrap(args["request"] as? [String: Any])
        XCTAssertEqual(Set(request.keys), ["address", "throughSeq", "beforeSeq", "maxMessages", "turnWindow"],
                       "水位与窗口五键，一个不多一个不少")
        XCTAssertEqual(request["throughSeq"] as? Int, 12, "切点原样带回（含端）")
        XCTAssertEqual(request["beforeSeq"] as? Int, 5, "下界是本地窗口起点（排他）")
        XCTAssertEqual(request["maxMessages"] as? Int, HistoryWindow.standard.maxMessages,
                       "窗口与打开会话同一份 —— 两处各写一遍就会长短不同")
        let address = try XCTUnwrap(request["address"] as? [String: Any])
        XCTAssertEqual(address["kind"] as? String, "session")
        XCTAssertEqual(address["sessionId"] as? String, "s-1")
    }

    /// 判据 7 的前半：`details` 要原样解出来。
    func testRefusalCarriesDetails() async throws {
        ScriptedURLProtocol.reset(replies: [
            "session/list": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"invalid-request","message":"bad","details":{"field":"workspaceId"}}}}"#
            ),
        ])

        do {
            let _: ListSessionsResponse = try await client().perform(ListSessionsRequest(), authenticated: false)
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
            "session/list": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"unknown-session","message":"gone"}}}"#
            ),
        ])

        do {
            let _: ListSessionsResponse = try await client().perform(ListSessionsRequest(), authenticated: false)
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

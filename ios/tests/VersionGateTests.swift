/**
 * 版本闸：说不到一块儿去时，立刻说清楚是哪一边旧。
 *
 * 这里守的是**不会静默降级**的两种形状：
 *
 * 1. 版本不同的应答被当成正常应答处理 —— 不会（`validate` 在唯一的出口上）。
 * 2. 版本不同被报成别的错误 —— 会，如果 decode 先失败的话。第二种更坏：人说「报文畸形」
 *    会去翻解码器，而真正该做的是升级 App。
 *
 * 用真 `URLSession` + `URLProtocol` 桩，测的是它自己怎么读回包。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class VersionGateTests: XCTestCase {

    private func transport() -> HttpTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return HttpTransport(session: { session },
                             baseURL: { URL(string: "http://127.0.0.1:3081")! })
    }

    /// 发一发 `list-sessions`，回包由 `body` 决定。返回抛出的错（成功时返回 `nil`）。
    private func error(from body: String) async -> Error? {
        ScriptedURLProtocol.reset(replies: [
            "list-sessions": .init(status: 200, body: body),
        ])
        do {
            _ = try await transport().send(
                ListSessionsRequest(),
                requestId: "version-gate",
                authorization: nil,
                treat401AsRefusal: false
            ) as ListSessionsResponse?
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 版本不同

    func testAVersionWeDoNotSpeakIsNeverTreatedAsSuccess() async {
        // 回包能解出来，但 `v` 不是我们的 —— 绝不能当成一次正常应答。
        let caught = await error(from: #"{"v":99,"ok":true,"sessions":[],"serverTime":0}"#)
        guard case .versionMismatch(let v)? = caught as? RpcClientError else {
            return XCTFail("应报 versionMismatch，实际是 \(String(describing: caught))")
        }
        XCTAssertEqual(v, 99)
    }

    /// **decode 先失败的那条路**。
    ///
    /// 网关升级后字段形状变了，`Response` 解不出来。不先探一眼版本的话，这里会报
    /// 「报文畸形」—— 于是人去翻解码器，而真正该做的是升级 App。
    func testAVersionMismatchIsNotReportedAsAMalformedResponse() async {
        // `ok` 是字符串：`ListSessionsResponse` 解不出来，但 `v` 读得出来。
        let caught = await error(from: #"{"v":99,"ok":"yes"}"#)
        guard case .versionMismatch(let v)? = caught as? RpcClientError else {
            return XCTFail("应报 versionMismatch，实际是 \(String(describing: caught))")
        }
        XCTAssertEqual(v, 99)
    }

    func testAMalformedResponseWithOurOwnVersionStaysMalformed() async {
        // 版本是我们的，只是报文坏了 —— 这时报「畸形」才对，不能倒过来误报成版本问题。
        let caught = await error(from: #"{"v":2,"ok":"yes"}"#)
        guard case .malformedResponse? = caught as? RpcClientError else {
            return XCTFail("应报 malformedResponse，实际是 \(String(describing: caught))")
        }
    }

    // MARK: - 文案的方向

    /// 「两端版本不一致」这句话本身不可行动。两个方向要做的事完全不同，所以文案必须分开。
    func testTheMessageSaysWhichSideIsBehind() {
        let newerGateway = RpcClientError.versionMismatch(gatewayProtocolVersion + 1)
            .errorDescription ?? ""
        XCTAssertTrue(newerGateway.contains("升级 App"),
                      "网关更新时该说升级客户端，实际：\(newerGateway)")

        let olderGateway = RpcClientError.versionMismatch(gatewayProtocolVersion - 1)
            .errorDescription ?? ""
        XCTAssertTrue(olderGateway.contains("升级 Mac 上的网关"),
                      "网关更旧时该说升级网关，实际：\(olderGateway)")
    }

    func testTheMessageCarriesBothVersions() {
        // 查的人第一件事就是想知道两个数字各是多少。
        let text = RpcClientError.versionMismatch(7).errorDescription ?? ""
        XCTAssertTrue(text.contains("v7"), "缺网关版本：\(text)")
        XCTAssertTrue(text.contains("v\(gatewayProtocolVersion)"), "缺本地版本：\(text)")
    }
}

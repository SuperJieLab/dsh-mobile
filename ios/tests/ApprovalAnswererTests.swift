/**
 * 真的那条作答路径：请求体里的三个字段。
 *
 * 三种结局的**分支**由假门守（`ApprovalStoreTests`）；这里守的是假门替不掉的那一半 ——
 * 真 `RpcClient` 发出去的那一发。「允许」写成常量 `allow` 时用户的拒绝会变成批准，
 * 而任何一条既有判据都不会红：假门只记「门被叫了一次」。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class ApprovalAnswererTests: XCTestCase {

    private func client() -> RpcClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        var stored: String? = "device-token"
        let store = CredentialStore(storage: .init(
            read: { stored },
            write: { stored = $0 },
            delete: { stored = nil }
        ))
        let session = URLSession(configuration: configuration)
        return RpcClient(session: { session },
                         baseURL: { URL(string: "http://127.0.0.1:3081")! },
                         credentials: store)
    }

    /// 脚本：换票 + 一条 ok 的应答。
    private func script() {
        ScriptedURLProtocol.reset(replies: [
            "mobile/refresh": .init(status: 200,
                                    body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"accessToken":"fresh","expiresAt":9999999999999,"deviceToken":"d"}}}"#),
            "mobile/approvalAnswer": .init(status: 200,
                                           body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"eventId":"e7"}}}"#),
        ])
    }

    /// 两个方向各一发：`allow` → `"allow"`、`deny` → `"deny"`，且 `answerId` 原样到达
    /// （它是幂等键：换一个值，重试就不再回放第一次的结果）。
    func testTheAnswerCarriesTheDirectionAndTheIdempotencyKey() async throws {
        script()
        let answerer = GatewayApprovalAnswerer(client: client())

        try await answerer.answer(eventId: "e7", allow: true, answerId: "answer-1")
        try await answerer.answer(eventId: "e7", allow: false, answerId: "answer-2")

        let sent = try XCTUnwrap(ScriptedURLProtocol.bodies["mobile/approvalAnswer"],
                                 "这一发没到达 mobile/approvalAnswer —— 先看端点名")
        XCTAssertEqual(sent.count, 2)
        // 参数在 `payload.args` 这一格容器里；体顶层只有信封的三格。
        let args = sent.compactMap { ($0["payload"] as? [String: Any])?["args"] as? [String: Any] }
        XCTAssertEqual(args.count, 2, "两发都该带 args")
        XCTAssertEqual(args[0]["decision"] as? String, "allow")
        XCTAssertEqual(args[1]["decision"] as? String, "deny", "用户按的是拒绝，发出去的必须是拒绝")
        XCTAssertEqual(args.map { $0["eventId"] as? String }, ["e7", "e7"])
        XCTAssertEqual(args.map { $0["answerId"] as? String }, ["answer-1", "answer-2"],
                       "幂等键由调用方给，这一层不得另造一个")
    }
}

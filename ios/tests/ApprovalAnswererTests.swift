/**
 * 真的那条作答路径：`$events/result` 的三键与两种结局词。
 *
 * 三种结局的**分支**由假门守（`ApprovalStoreTests`）；这里守的是假门替不掉的那一半 ——
 * 真 `RpcClient` 发出去的那一发。「允许」写成常量 `allowed-once` 时用户的拒绝会变成
 * 批准，而任何一条既有判据都不会红：假门只记「门被叫了一次」。
 *
 * 客户端幂等键不在了（第 3 期）：幂等由上游承担，判据因此盯「有没有多出一格」。
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
            "$events/result": .init(status: 200,
                                    body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"ok":true}}}"#),
        ])
    }

    /// 两个方向各一发：`.allowedOnce` → `"allowed-once"`、`.rejected` → `"rejected"`；
    /// 三键平铺、`outcome` 只有 `kind` 与 `value`，**没有客户端幂等键**。
    func testTheAnswerCarriesTheUpstreamOutcomeWord() async throws {
        script()
        let answerer = GatewayApprovalAnswerer(client: client())

        try await answerer.answer(eventId: "e7", decision: .allowedOnce, clientId: "c-9")
        try await answerer.answer(eventId: "e7", decision: .rejected, clientId: "c-9")

        let sent = try XCTUnwrap(ScriptedURLProtocol.bodies["$events/result"],
                                 "这一发没到达 $events/result —— 先看端点名")
        XCTAssertEqual(sent.count, 2)
        // 参数在 `payload.args` 这一格容器里；体顶层只有信封的三格。
        let args = sent.compactMap { ($0["payload"] as? [String: Any])?["args"] as? [String: Any] }
        XCTAssertEqual(args.count, 2, "两发都该带 args")
        XCTAssertEqual(Set(args[0].keys), ["clientId", "eventId", "outcome"], "三键平铺，没有第四格")
        XCTAssertEqual(args.map { $0["eventId"] as? String }, ["e7", "e7"])
        XCTAssertEqual(args.map { $0["clientId"] as? String }, ["c-9", "c-9"],
                       "归属的键必须出现在线上 —— 丢了它网关只会回 not-owner")

        let outcomes = args.compactMap { $0["outcome"] as? [String: Any] }
        XCTAssertEqual(outcomes.map { $0["kind"] as? String }, ["result", "result"])
        XCTAssertEqual(outcomes.map { $0["value"] as? String }, ["allowed-once", "rejected"],
                       "结局词直接是上游那两个 —— 用户按的是拒绝，发出去的必须是拒绝")
    }
}

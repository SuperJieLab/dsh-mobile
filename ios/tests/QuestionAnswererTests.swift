/**
 * 提问应答的那一发：`$events/result` 的三键，`value` 是整批答案。
 *
 * 与 `ApprovalAnswererTests` 并列，守的是它替不掉的那一半：`.answers` 的编码是**手写的**
 * （`RemoteEventValue.encode`），写成 `answer`、或把它编成裸数组，假 answerer 全绿而
 * 上游会整批拒 —— 用户点了提交，卡一直转，没有任何一处报错。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class QuestionAnswererTests: XCTestCase {

    private func client() -> RpcClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        let store = CredentialStore(storage: .init(
            read: { nil },
            write: { _ in },
            delete: {}
        ))
        let session = URLSession(configuration: configuration)
        return RpcClient(session: { session },
                         baseURL: { URL(string: "http://127.0.0.1:3081")! },
                         credentials: store)
    }

    func testTheAnswerCarriesTheWholeBatchUnderAnswers() async throws {
        ScriptedURLProtocol.reset(replies: [
            "$events/result": .init(
                status: 200,
                body: #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"ok":true}}}"#
            ),
        ])

        try await GatewayQuestionAnswerer(client: client()).answer(
            eventId: "q-1",
            answers: [
                QuestionAnswerItem(id: "q-1-a", selected: ["A"], custom: nil),
                QuestionAnswerItem(id: "q-1-b", selected: [], custom: "都要"),
            ],
            clientId: "c-9"
        )

        let sent = try XCTUnwrap(ScriptedURLProtocol.bodies["$events/result"],
                                 "这一发没到达 $events/result —— 先看端点名")
        let body = try XCTUnwrap(sent.first, "没有收到请求体")
        let args = try XCTUnwrap((body["payload"] as? [String: Any])?["args"] as? [String: Any])
        XCTAssertEqual(Set(args.keys), ["clientId", "eventId", "outcome"], "三键平铺，没有第四格")
        XCTAssertEqual(args["clientId"] as? String, "c-9", "归属的键必须出现在线上")
        XCTAssertEqual(args["eventId"] as? String, "q-1")

        let outcome = try XCTUnwrap(args["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["kind"] as? String, "result")

        // 这一格是手写编码器：形状错了不会在 Swift 侧报错，只会被上游整批拒。
        let value = try XCTUnwrap(outcome["value"] as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["answers"], "整批答案在 `answers` 里 —— 不是裸数组、不是 `answer`")
        let answers = try XCTUnwrap(value["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers.map { $0["id"] as? String }, ["q-1-a", "q-1-b"])
        XCTAssertEqual(answers[0]["selected"] as? [String], ["A"])
        XCTAssertNil(answers[0]["custom"], "`custom` 缺席时整个键不出现 —— 缺席 ≠ 空串")
        XCTAssertEqual(answers[1]["selected"] as? [String], [])
        XCTAssertEqual(answers[1]["custom"] as? String, "都要")
    }
}

/**
 * 问题应答：整批提交、半张卡不投、被拒留卡、没键不发。
 *
 * 与 `ApprovalStoreTests` 的分工：那边验审批那条链路，这边验提问。共用的三态
 * （`AnswerProgress`）只在审批那边验一次 —— 它现在只有一份定义。
 */
import XCTest

@testable import DshMobile

@MainActor
final class QuestionStoreTests: XCTestCase {

    private final class FakeAnswerer: QuestionAnswering {
        var calls: [(eventId: String, answers: [QuestionAnswerItem], clientId: String)] = []
        var error: Error?

        func answer(eventId: String, answers: [QuestionAnswerItem], answerId: String, clientId: String) async throws {
            calls.append((eventId, answers, clientId))
            if let error { throw error }
        }
    }

    private final class Sink: PendingEventSink {
        var clientId: String?
        private(set) var questions: [(JSONValue) -> Void] = []
        private(set) var cancels: [(JSONValue) -> Void] = []

        init(clientId: String?) { self.clientId = clientId }

        func onApproval(_ handler: @escaping (JSONValue) -> Void) -> () -> Void { {} }
        func onQuestion(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
            questions.append(handler)
            return {}
        }
        func onCancel(_ handler: @escaping (JSONValue) -> Void) -> () -> Void {
            cancels.append(handler)
            return {}
        }
        func onReady(_ handler: @escaping () -> Void) -> () -> Void { {} }
        func onEmit(_ handler: @escaping (String, JSONValue) -> Void) -> () -> Void { {} }
    }

    private func payload(_ eventId: String, sessionId: String = "s1") -> JSONValue {
        .object([
            "event": .string("user-questions/request"),
            "eventId": .string(eventId),
            "agentId": .string(sessionId),
            "request": .object([
                "questions": .array([
                    .object([
                        "id": .string("q-1"), "question": .string("用哪条？"),
                        "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])]),
                    ]),
                    .object([
                        "id": .string("q-2"), "question": .string("同时改测试吗？"),
                        "options": .array([.object(["label": .string("要")]), .object(["label": .string("不要")])]),
                        "multiSelect": .bool(true),
                    ]),
                ]),
            ]),
        ])
    }

    private func store(clientId: String? = "c1") -> (QuestionStore, FakeAnswerer, Sink) {
        let answerer = FakeAnswerer()
        let questionStore = QuestionStore(answerer: answerer)
        let sink = Sink(clientId: clientId)
        questionStore.attach(sink: sink)
        for handler in sink.questions { handler(payload("q1")) }
        return (questionStore, answerer, sink)
    }

    func testAFullSubmissionCarriesEveryQuestionOnce() async {
        let (store, answerer, _) = store()
        let entry = try! XCTUnwrap(store.pending(in: "s1").first)

        await store.answer(entry, selections: [
            "q-1": .init(selected: ["A"]),
            "q-2": .init(selected: ["要", "不要"], custom: "顺便加个用例"),
        ])

        XCTAssertEqual(answerer.calls.count, 1)
        let answers = answerer.calls.first?.answers ?? []
        XCTAssertEqual(answers.map(\.id), ["q-1", "q-2"], "整批提交，一个不缺一个不多")
        XCTAssertEqual(answers.first?.selected, ["A"])
        XCTAssertEqual(answers.last?.selected, ["要", "不要"], "多选两项都要在")
        XCTAssertEqual(answers.last?.custom, "顺便加个用例", "自定义文本与选项并存")
        XCTAssertEqual(store.pending(in: "s1"), [], "成功后卡消失")
        XCTAssertEqual(store.notice(for: "s1"), "已投递")
    }

    func testAHalfAnsweredCardIsNotSent() async {
        let (store, answerer, _) = store()
        let entry = try! XCTUnwrap(store.pending(in: "s1").first)

        XCTAssertFalse(QuestionAnswers.isComplete(entry, selections: [
            "q-1": .init(selected: ["A"]),
        ]), "第二问没答 → 不算完整")

        await store.answer(entry, selections: ["q-1": .init(selected: ["A"])])

        XCTAssertEqual(answerer.calls.count, 0, "半张卡不投 —— 网关也会拒，但那要多走一趟且样子分不开")
        XCTAssertEqual(store.pending(in: "s1").count, 1, "卡还在")
    }

    func testARefusedSubmissionKeepsTheCardWithAReason() async {
        let (store, answerer, _) = store()
        answerer.error = RpcClientError.refused(GatewayFailure(
            code: GatewayErrorCode.invalidRequest.rawValue, message: "答案与卡不匹配", details: [:]
        ))
        let entry = try! XCTUnwrap(store.pending(in: "s1").first)

        await store.answer(entry, selections: [
            "q-1": .init(selected: ["A"]), "q-2": .init(selected: ["要"]),
        ])

        XCTAssertEqual(store.pending(in: "s1").count, 1, "被拒不是作废 —— 卡留着")
        if case .refused(let reason)? = store.state(for: "q1") {
            XCTAssertTrue(reason.contains("不匹配"), "原因要写明：\(reason)")
        } else {
            XCTFail("该落在 .refused，实际 \(String(describing: store.state(for: "q1")))")
        }
    }

    func testWithoutAClientIdNothingIsSent() async {
        let (store, answerer, _) = store(clientId: nil)
        let entry = try! XCTUnwrap(store.pending(in: "s1").first)

        await store.answer(entry, selections: [
            "q-1": .init(selected: ["A"]), "q-2": .init(selected: ["要"]),
        ])

        XCTAssertEqual(answerer.calls.count, 0, "注定被拒的请求不发")
        XCTAssertEqual(store.state(for: "q1"), .unknown, "但要说「不知道结果」，不是「没做过」")
    }
}

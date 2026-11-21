/**
 * 问题表：读得出、入得栏、坏形状整条丢。
 */
import XCTest

final class QuestionTableTests: XCTestCase {

    private func frame(_ request: JSONValue, eventId: String = "q1", agentId: String = "s1") -> JSONValue {
        .object([
            "event": .string("user-questions/request"),
            "eventId": .string(eventId),
            "agentId": .string(agentId),
            "request": request,
        ])
    }

    func testItReadsARealQuestionShapeAndFilesItUnderItsSession() {
        var table = QuestionTable()
        table.absorb(frame(.object([
            "questions": .array([
                .object([
                    "id": .string("q-1"),
                    "header": .string("选择方案"),
                    "question": .string("用哪一条？"),
                    "options": .array([
                        .object(["label": .string("A"), "description": .string("快")]),
                        .object(["label": .string("B")]),
                    ]),
                ]),
                .object([
                    "id": .string("q-2"),
                    "question": .string("同时改测试吗？"),
                    "options": .array([.object(["label": .string("要")])]),
                    "multiSelect": .bool(true),
                ]),
            ]),
        ])))

        let pending = table.pending(in: "s1")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.eventId, "q1")
        XCTAssertEqual(pending.first?.questions.count, 2)
        // 第一问：单选（缺省）、带 header、两个选项、第一个有 description
        XCTAssertEqual(pending.first?.questions.first?.multiSelect, false)
        XCTAssertEqual(pending.first?.questions.first?.header, "选择方案")
        XCTAssertEqual(pending.first?.questions.first?.options.count, 2)
        XCTAssertEqual(pending.first?.questions.first?.options.first?.note, "快")
        // 第二问：显式多选、没有 header
        XCTAssertEqual(pending.first?.questions.last?.multiSelect, true)
        XCTAssertEqual(pending.first?.questions.last?.header, nil)
        XCTAssertEqual(table.pending(in: "s2").count, 0, "按会话入栏 —— 别的会话看不到它")
    }

    func testABrokenShapeIsDroppedWhole() {
        var table = QuestionTable()
        // 缺 questions
        table.absorb(frame(.object([:]), eventId: "q-a"))
        // 某问缺 id
        table.absorb(frame(.object(["questions": .array([.object(["question": .string("没有 id")])])]), eventId: "q-b"))
        // 某问缺 question
        table.absorb(frame(.object(["questions": .array([.object(["id": .string("q-1")])])]), eventId: "q-c"))
        // 空数组
        table.absorb(frame(.object(["questions": .array([])]), eventId: "q-d"))

        XCTAssertEqual(table.entries, [], "读不出就整条丢 —— 一张缺题的卡比没有卡更坏")
    }

    func testRemoveAndClearDropTheWholeCard() {
        var table = QuestionTable()
        table.absorb(frame(.object(["questions": .array([.object(["id": .string("q-1"), "question": .string("甲")])])]), eventId: "q1"))
        table.absorb(frame(.object(["questions": .array([.object(["id": .string("q-2"), "question": .string("乙")])])]), eventId: "q2"))
        XCTAssertEqual(table.entries.count, 2)

        table.remove(eventId: "q1")
        XCTAssertEqual(table.entries.map(\.eventId), ["q2"])

        table.clear()
        XCTAssertEqual(table.entries, [], "换代清空 —— 之后由网关重放重建")
    }
}

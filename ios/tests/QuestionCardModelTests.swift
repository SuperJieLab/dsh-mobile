/**
 * 卡片的值判定：`intent` 只有一条路、`detail` 不进模型、答全才可交。
 */
import XCTest

@testable import DshMobile

final class QuestionCardModelTests: XCTestCase {

    private func entry(intent: String?) -> QuestionTable.Entry {
        QuestionTable.Entry(eventId: "q1", sessionId: "s1", questions: [
            QuestionTable.Question(
                id: "q-1", header: "选择方案", question: "用哪一条？",
                options: [.init(label: "A", note: "快"), .init(label: "B", note: nil)],
                multiSelect: false, intent: intent
            ),
        ])
    }

    func testEveryIntentIsDrawnTheSameWay() {
        // 三种 intent 得到同一组可见题 —— 呈现只有一条路（S6）。
        let plain = QuestionCardModel(entry: entry(intent: nil)).visibleQuestions
        let review = QuestionCardModel(entry: entry(intent: "plan-review")).visibleQuestions
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(review.map(\.id), plain.map(\.id), "plan-review 不换画法、不少一道题")
        // `detail` 是正文，不在题目里 —— 模型里因此没有它。
        XCTAssertEqual(review.first?.question, "用哪一条？", "显示的是题干，不是正文")
    }

    func testItIsSubmittableOnlyWhenEveryQuestionHasAValue() {
        let model = QuestionCardModel(entry: entry(intent: nil))

        XCTAssertFalse(model.canSubmit([:]), "一问没答 → 不能交")
        XCTAssertFalse(model.canSubmit(["q-1": .init(selected: [])]), "勾了空集合、也没自定义 → 不能交")
        let blankOnly: [String: QuestionSelection] = ["q-1": .init(selected: [], custom: "   ")]
        XCTAssertFalse(model.canSubmit(blankOnly), "只有空白 → 不能交（与网关的 trim 判据同一条规则）")
        XCTAssertTrue(model.canSubmit(["q-1": .init(selected: ["A"])]), "选了选项 → 能交")
        XCTAssertTrue(model.canSubmit(["q-1": .init(selected: [], custom: "其它回答")]), "只有自定义文本 → 能交")
    }

    func testThePayloadKeepsOptionsAndCustomTogether() {
        let model = QuestionCardModel(entry: QuestionTable.Entry(eventId: "q1", sessionId: "s1", questions: [
            QuestionTable.Question(
                id: "q-2", header: nil, question: "同时改测试吗？",
                options: [.init(label: "要", note: nil), .init(label: "不要", note: nil)],
                multiSelect: true, intent: nil
            ),
        ]))
        let payload = QuestionAnswers.payload(
            model.entry,
            selections: ["q-2": .init(selected: ["要", "不要"], custom: " 顺便加个用例 ")]
        )
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload.first?.selected, ["要", "不要"], "多选两项都保留，顺序按选项顺序")
        XCTAssertEqual(payload.first?.custom, "顺便加个用例", "自定义文本两头空白被去掉")
    }
}

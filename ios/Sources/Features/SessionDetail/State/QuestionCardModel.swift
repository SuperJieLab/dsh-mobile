/**
 * 问题卡的取值与判定 —— **纯值，不含视图**。
 *
 * 单独一个文件是为了让它能被当值测：视图（`QuestionCard`）只画它给的东西，
 * 「`intent` 怎么分派」与「什么算答全」两条规则都落在这里。
 */
import Foundation

/// 卡片的取值与判定（值类型，可单独测 —— 视图只画它给的东西）。
struct QuestionCardModel {

    let entry: QuestionTable.Entry

    /// 要显示的题。`intent` 的分派点在这里：本期只有默认分支。
    var visibleQuestions: [QuestionTable.Question] {
        entry.questions.filter { question in
            switch question.intent {
            default:
                // 用户裁决：`plan-review` 的正文先不展示。这里留判别点是为了将来
                // 只加一个分支，而不是重排卡片 —— 空 `case` 不写，它会被读成「已处理」。
                return true
            }
        }
    }

    /// 每一问都答过了才能交 —— 与 `QuestionStore` 的守卫读同一个谓词。
    func canSubmit(_ selections: [String: QuestionSelection]) -> Bool {
        // 读 `visibleQuestions` 而不是 `entry.questions`：将来真有分支藏起某问时，
        // 被藏起来的那一问不该继续挡住提交。
        QuestionAnswers.isComplete(visibleQuestions, selections: selections)
    }
}

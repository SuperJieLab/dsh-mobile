/**
 * 待答提问的表：按会话分组存着「还挂着的项」，随帧增删，不随界面生死。纯值类型。
 *
 * 与 `ApprovalTable` 分开是因为**行形状完全不同**（那边是 `toolName` + `reason`，这边是
 * 一组带选项的题），共用一张表会让每个读的人都得判空。两张表在同一个 Store 里，`cancel`
 * 与 `ready` 各删各的 —— 它们共用的只有「按 `eventId` 寻址」这一件事。
 *
 * 读不出题目的载荷**整条丢**，不留半张卡：一张缺了问题的卡比没有卡更坏，用户会以为
 * 「只有这一个问题」。
 */
import Foundation

struct QuestionTable {

    /// 一个问题的一个选项。
    struct Option: Identifiable, Equatable {
        let label: String
        /// 选项的补充说明（上游的 `description`）；可缺。
        ///
        /// **不叫 `detail`**：那个名字在协议里指「plan-review 的正文」，用户裁决先不展示 ——
        /// 两个东西同名会让人以为这里也要剥。
        let note: String?

        var id: String { label }
    }

    /// 一道题 —— 卡上要显示的东西全在这里。
    struct Question: Identifiable, Equatable {
        let id: String
        /// 小标题，可缺。
        let header: String?
        let question: String
        /// 可缺（缺省为空 = 只有自定义文本可填）。
        let options: [Option]
        /// 缺省是单选。
        let multiSelect: Bool
        /// 上游给的类型提示（`plan-review` 之类）。**不参与画法分派** ——
        /// 用户裁决先不按它换样式，判别点留在卡片的 `visibleQuestions` 里。
        let intent: String?
    }

    /// 一张卡 —— 一条 `user-questions/request` 可以带多问。
    struct Entry: Identifiable, Equatable {
        /// 身份 = 投递编号：跨代稳定，也是 `cancel` 唯一携带的字段。
        let eventId: String
        /// 属于哪个会话 —— 分组键，来自帧的 `agentId`。
        let sessionId: String
        let questions: [Question]

        var id: String { eventId }

        /// 要显示的题。`intent` 的分派点**在这里**：卡片与「答全」判定都读它，
        /// 所以「藏起某一问」不会变成「按钮可点、点了没反应」。
        ///
        /// 用户裁决：`plan-review` 的正文先不展示。留判别点是为了将来只加一个分支 ——
        /// 不写空 `case`，它会被读成「已处理」。
        var visibleQuestions: [Question] {
            questions.filter { question in
                switch question.intent {
                default:
                    return true
                }
            }
        }
    }

    /// 按到达顺序 —— 与审批同一份集合语义，重放时顺序即到达顺序。
    private(set) var entries: [Entry] = []

    /// 收下一条提问的载荷：按 `eventId` 覆盖或追加。
    /// 载荷是上游 waterfall 的四个字段原样（`event` / `eventId` / `agentId` / `request`）。
    mutating func absorb(_ payload: JSONValue) {
        guard let eventId = payload["eventId"]?.string, !eventId.isEmpty,
              let sessionId = payload["agentId"]?.string, !sessionId.isEmpty,
              let questions = Self.questions(of: payload["request"]?["questions"])
        else {
            Log.warn(Log.Module.session, "dropped a question without a session, an address or a readable question")
            return
        }
        let entry = Entry(eventId: eventId, sessionId: sessionId, questions: questions)
        if let index = entries.firstIndex(where: { $0.eventId == entry.eventId }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// 撤回（或已从别处答过）：只给得出投递编号。
    mutating func remove(eventId: String) {
        entries.removeAll { $0.eventId == eventId }
    }

    /// 换代：网关随后重放当前集合，这里是它重建的起点。
    mutating func clear() {
        entries.removeAll()
    }

    /// 某个会话还挂着的项，按到达顺序。
    func pending(in sessionId: String) -> [Entry] {
        entries.filter { $0.sessionId == sessionId }
    }

    /// 解析 `request.questions`。任何一问读不出 `id` 或 `question` 就整条作废 ——
    /// 与审批「读不出 `toolName` 就不收」同一条纪律。
    private static func questions(of raw: JSONValue?) -> [Question]? {
        guard let items = raw?.array, !items.isEmpty else { return nil }
        var questions: [Question] = []
        for item in items {
            guard let id = item["id"]?.string, !id.isEmpty,
                  let question = item["question"]?.string, !question.isEmpty
            else { return nil }
            let options = (item["options"]?.array ?? []).compactMap { option -> Option? in
                guard let label = option["label"]?.string, !label.isEmpty else { return nil }
                return Option(label: label, note: option["description"]?.string)
            }
            questions.append(Question(
                id: id,
                header: item["header"]?.string,
                question: question,
                options: options,
                multiSelect: item["multiSelect"]?.bool ?? false,
                intent: item["intent"]?.string
            ))
        }
        return questions
    }
}

/// 一张卡的答案判定与收口 —— 与「谁在持有表」无关，所以**不挂在 Store 上**：
/// 视图模型（值）与 Store（`@MainActor`）都要读它，挂在 Store 上会逼着视图也进主 actor。
enum QuestionAnswers {

    /// 每一问都答过了才算能交。**唯一谓词**：卡片按钮与 Store 的守卫都读它。
    static func isComplete(_ entry: QuestionTable.Entry, selections: [String: QuestionSelection]) -> Bool {
        isComplete(entry.visibleQuestions, selections: selections)
    }

    /// 按题目列表判 —— 卡片读的是 `visibleQuestions`（将来可能比 `entry.questions` 少），
    /// 两处若各读各的，被藏起来的那一问会让卡**永远交不出去**。
    static func isComplete(_ questions: [QuestionTable.Question], selections: [String: QuestionSelection]) -> Bool {
        questions.allSatisfy { question in
            guard let selection = selections[question.id] else { return false }
            return !selection.selected.isEmpty
                || !selection.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 把选择收成线上形状。调用前必须已经 `isComplete`。
    static func payload(_ entry: QuestionTable.Entry, selections: [String: QuestionSelection]) -> [QuestionAnswerItem] {
        entry.visibleQuestions.compactMap { question in
            guard let selection = selections[question.id] else { return nil }
            let custom = selection.custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return QuestionAnswerItem(
                id: question.id,
                selected: question.options.map(\.label).filter { selection.selected.contains($0) },
                custom: custom.isEmpty ? nil : custom
            )
        }
    }
}


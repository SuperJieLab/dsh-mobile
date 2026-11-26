/**
 * 一张待答提问卡：展示每道题与它的选项，收齐后一次提交。
 *
 * 呈现**只有一条路**：不按 `intent` 换画法，不展示 `detail`（plan-review 的正文）。
 * 判别点留在 `QuestionCardModel.visibleQuestions` 里 —— 将来要多一种画法时，只加一个
 * 分支，而不是重排卡片。
 */
import SwiftUI

struct QuestionCard: View {

    let model: QuestionCardModel
    let state: AnswerProgress?
    let onSubmit: ([String: QuestionStore.Selection]) -> Void

    /// 本地编辑态：勾了哪些、每一问的自定义文本。提交后由 Store 撤卡，这里跟着消失。
    @State private var selections: [String: QuestionStore.Selection] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DSH 有问题要问你", systemImage: "questionmark.bubble.fill")
                .font(.caption)
                .foregroundStyle(.blue)

            ForEach(model.visibleQuestions) { question in
                questionBlock(question)
            }

            switch state {
            case .sending:
                Text(ApprovalStore.sendingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .unknown:
                Text(ApprovalStore.unknownNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .refused(let reason):
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case nil:
                Button {
                    onSubmit(selections)
                } label: {
                    Text("提交")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit(selections))
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func questionBlock(_ question: QuestionTable.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .font(.subheadline)
                .textSelection(.enabled)

            ForEach(question.options) { option in
                optionRow(question: question, option: option)
            }

            TextField(question.options.isEmpty ? "回答" : "其它（可填）", text: customBinding(question), axis: .vertical)
                .font(.footnote)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func optionRow(question: QuestionTable.Question, option: QuestionTable.Option) -> some View {
        let picked = selections[question.id]?.selected.contains(option.label) ?? false
        return Button {
            toggle(question: question, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: image(for: picked, multi: question.multiSelect))
                    .foregroundStyle(picked ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.footnote)
                    // 选项说明（上游的 `description`）—— 与 plan-review 的正文不是一回事。
                    if let note = option.note, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    private func image(for picked: Bool, multi: Bool) -> String {
        if multi { return picked ? "checkmark.square.fill" : "square" }
        return picked ? "largecircle.fill.circle" : "circle"
    }

    /// 单选换一个、多选增删一个。
    private func toggle(question: QuestionTable.Question, label: String) {
        var selection = selections[question.id] ?? .init()
        if question.multiSelect {
            if selection.selected.contains(label) { selection.selected.remove(label) }
            else { selection.selected.insert(label) }
        } else {
            selection.selected = selection.selected == [label] ? [] : [label]
        }
        selections[question.id] = selection
    }

    private func customBinding(_ question: QuestionTable.Question) -> Binding<String> {
        Binding(
            get: { selections[question.id]?.custom ?? "" },
            set: { text in
                var selection = selections[question.id] ?? .init()
                selection.custom = text
                selections[question.id] = selection
            }
        )
    }
}

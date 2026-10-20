import SwiftUI

/// 模型选择按钮：功能条中间那一格。
///
/// 显示规则照上游（`ui-model-selection` 的显示式）：当前值 = 宿主给的显示值 ?? 目录默认
/// —— 服务端没说「下一轮用什么」时退到部署默认，**不猜别的**。这条兜底规则要读目录，
/// 所以它的结果由宿主算好传进来（`name`）。
///
/// 拉取失败的 provider 灰显并给整表重试；失败的明细不逐条重试（demo 粒度）。
///
/// **取数不在这里**：「等待 / 有内容 / 失败 + 原因」三面归 `ModelCatalogState`，本视图只读。
/// 目录的**拉取时机归宿主**（进屏一次）—— 挂在这里的话，功能条每次因键盘收起而重建都会
/// 重拉一遍，把已成功的目录又打回 `.waiting`。
struct ModelPickerView: View {
    /// 目录的三面。取数与判定都在里面，这里只读 —— 由宿主持有并传进来。
    @ObservedObject var catalog: ModelCatalogState
    /// 宿主给的当前选择；菜单里打勾用。
    let selected: ModelSelection?
    /// 宿主算好的显示名（选中值 ?? 目录默认值 ?? 未知）。
    let name: String
    /// 选一个模型。接到哪条编排上由宿主决定。
    let onSelect: (ModelSelection) -> Void

    var body: some View {
        Menu {
            menuContent
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(name)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        switch catalog.outcome {
        case .waiting:
            Text("目录加载中…")

        case .failed(let cause):
            Section("目录不可用") {
                Text(cause.line)
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await catalog.reload() } }
            }

        case .ready(let list):
            sections(of: list)
        }
    }

    @ViewBuilder
    private func sections(of list: ModelCatalog) -> some View {
        let groups = list.groups ?? []
        let failures = list.failures ?? []
        // 空目录也是成功面 —— 空菜单与「没加载出来」在屏幕上会看起来一样。
        if groups.isEmpty && failures.isEmpty {
            Text(ModelCatalog.emptyNote)
        }
        ForEach(groups, id: \.id) { group in
            Section(group.name) {
                ForEach(group.models, id: \.id) { entry in
                    Button {
                        onSelect(ModelSelection(provider: group.id, model: entry.id))
                    } label: {
                        if selected?.provider == group.id, selected?.model == entry.id {
                            Label(entry.name, systemImage: "checkmark")
                        } else {
                            Text(entry.name)
                        }
                    }
                }
            }
        }
        if !failures.isEmpty {
            Section("暂时不可用") {
                ForEach(failures, id: \.id) { failure in
                    // 失败隔离（上游同语义）：一个 provider 拉不到不挡其余，灰显说原因。
                    Text("\(failure.name)（\(failure.message)）")
                        .foregroundStyle(.secondary)
                }
                Button("重试") { Task { await catalog.reload() } }
            }
        }
    }
}

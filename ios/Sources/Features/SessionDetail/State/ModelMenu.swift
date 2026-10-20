/**
 * 模型选择器的预构数据 —— 两个维度（模型、推理等级）各自的入口，加上选中态。
 *
 * 判定全部在这里完成：点哪一项该发什么选择，由 `selection` 随身携带 —— 视图不拼
 * `ModelSelection`，所以「换模型用新模型的默认档」这条规则只有一个地方可写。
 *
 * 与 `ModelCatalogState` 的分工：那边只管目录的三面（等待 / 有内容 / 失败）与取数，
 * 这里只管「拿这份目录画成什么」。等级名的解析两处共用同一份私有实现，不另写一遍。
 *
 * 本文件不出现用户可见文案（`LayeringTests.testStateHasNoUserFacingStrings`）：
 * 「不指定」叫什么由 `Display/CatalogText.swift` 决定。
 */
import Foundation

/// 一次预构的结果：模型子菜单的分组项、等级子菜单的档位、触发按钮上的等级名。
struct ModelMenu: Equatable {

    /// 一个 provider 分组 —— 与目录的分组同名，`id` 就是 provider id。
    struct Group: Equatable, Identifiable {
        let id: String
        let name: String
        let choices: [ModelChoice]
    }

    /// 按 provider 分组：根层「模型」子菜单的内容。
    let groups: [Group]
    /// 当前模型可选的档位：根层「推理等级」子菜单的内容。空 = 不提供这一级。
    let levels: [EffortChoice]
    /// 当前等级的名字（取自目录的 `name`）；`nil` = 不显示等级。
    let effortLabel: String?
    /// 当前生效那一项的 `EffortChoice.id`；`nil` = 没有可选的项。
    ///
    /// 与 `effortLabel` 同源（同一个解析），因为选择控件与显示必须对同一项打勾 ——
    /// 各算一遍就会出现「行里写着高、菜单里勾在低」。
    let selectedLevelID: String?
    let failures: [ModelCatalogFailure]
    /// 目录成功却一个模型都没有 —— 视图据此说「没有可用的模型」。
    let isEmpty: Bool
}

/// 一个模型项。点它发 `selection`：`reasoningEffort` 是该模型的默认档（可能没有）。
struct ModelChoice: Equatable, Identifiable {
    var id: String { "\(selection.provider)/\(selection.model)" }
    let label: String
    let selection: ModelSelection
    let isSelected: Bool
}

/// 一个档位项。点它发 `selection`：带上这一档，或「不指定」。
struct EffortChoice: Equatable, Identifiable {

    /// 这一项叫什么。分两态而不是存字符串：`unspecified` 的说法归显示层，
    /// 存成字符串就会把一句用户可见文案钉在编排层里。
    enum Label: Equatable {
        /// 目录里声明的档名（`efforts[].name`）。
        case declared(String)
        /// 「不指定」—— 仅在模型没声明 `defaultEffort` 时出现。
        case unspecified
    }

    /// 「不指定」那一项的 id。它不是一个档，所以不能借用某个档名占位。
    static let unspecifiedID = "#unspecified"

    var id: String { selection.reasoningEffort ?? Self.unspecifiedID }
    let label: Label
    let selection: ModelSelection
    let isSelected: Bool
}

extension ModelCatalogState {

    /// 拿当前目录预构菜单；目录还没到（等待 / 失败）时返回 `nil`，三面仍由视图按
    /// `outcome` 画 —— 这里不重复表达「加载中」。
    ///
    /// - Parameter selected: 宿主当前显示的选择；`nil` 时退到目录的部署默认值。
    func menu(selected: ModelSelection?) -> ModelMenu? {
        guard case .ready(let catalog) = outcome else { return nil }
        let current = selected ?? catalog.default
        let groups = (catalog.groups ?? []).map { group in
            ModelMenu.Group(id: group.id, name: group.name, choices: group.models.map { entry in
                ModelChoice(
                    label: entry.name,
                    // 点模型即选中，并**显式**带上该模型的默认档：留空会让宿主退到
                    // 部署默认，与「这个模型的默认」不是一回事（上游同款）。
                    selection: ModelSelection(provider: group.id,
                                              model: entry.id,
                                              reasoningEffort: entry.reasoning?.defaultEffort),
                    isSelected: current?.provider == group.id && current?.model == entry.id
                )
            })
        }
        let effective = effectiveEffortID(for: current, in: catalog)
        return ModelMenu(
            groups: groups,
            levels: levels(for: current, effective: effective, in: catalog),
            effortLabel: levelName(effective, in: catalog, of: current),
            selectedLevelID: effective,
            failures: catalog.failures ?? [],
            isEmpty: groups.allSatisfy { $0.choices.isEmpty } && (catalog.failures ?? []).isEmpty
        )
    }

    /// 触发按钮上的等级名。**轻量**：每次界面重绘都会问它，不预构整份菜单。
    func effortLabel(for selection: ModelSelection?) -> String? {
        guard case .ready(let catalog) = outcome else { return nil }
        let shown = selection ?? catalog.default
        return levelName(effectiveEffortID(for: shown, in: catalog), in: catalog, of: shown)
    }

    /// 当前**实际生效**的那一档的 id —— 等级列表的勾、设置页那一行的值、Picker 的选中项
    /// 三处共用它。
    ///
    /// 兜底顺序：显示值（且这一档还在目录里）→ 该模型的默认档 → 「不指定」（仅当模型没声明
    /// 默认档）。**这一处不许各算一遍**：算两遍就会出现「行里写着高、菜单里勾在低」——
    /// 显示值指向一个已撤下的档时，两边对「哪一项算选中」的答案本来就不一样。
    private func effectiveEffortID(for selection: ModelSelection?, in catalog: ModelCatalog) -> String? {
        guard let selection, let reasoning = catalog.reasoning(provider: selection.provider, model: selection.model) else {
            return nil
        }
        let declared = Set(reasoning.efforts.map(\.id))
        if let shown = selection.reasoningEffort, declared.contains(shown) { return shown }
        if let fallback = reasoning.defaultEffort, declared.contains(fallback) { return fallback }
        return reasoning.defaultEffort == nil ? EffortChoice.unspecifiedID : nil
    }

    /// 该档位菜单的内容。模型没有 `reasoning` → 空（设置页那一行换成说明）。
    ///
    /// 两条规则照上游：模型没声明 `defaultEffort` 时首项是「不指定」（选中它 = 让宿主
    /// 决定）；声明了就只列各档 —— 默认档本身就是其中一项，再给「不指定」会造出两个
    /// 发同样请求的选项。
    private func levels(for selection: ModelSelection?,
                        effective: String?,
                        in catalog: ModelCatalog) -> [EffortChoice] {
        guard let selection, let reasoning = catalog.reasoning(provider: selection.provider, model: selection.model) else {
            return []
        }
        var choices: [EffortChoice] = []
        if reasoning.defaultEffort == nil {
            choices.append(EffortChoice(
                label: .unspecified,
                selection: ModelSelection(provider: selection.provider, model: selection.model),
                isSelected: effective == EffortChoice.unspecifiedID
            ))
        }
        choices += reasoning.efforts.map { effort in
            EffortChoice(
                label: .declared(effort.name),
                selection: ModelSelection(provider: selection.provider,
                                          model: selection.model,
                                          reasoningEffort: effort.id),
                isSelected: effort.id == effective
            )
        }
        return choices
    }

    /// 档名：按**已生效**的那一档查目录里的 `name`；「不指定」与查不到都给 `nil`（不显示）。
    ///
    /// 「不指定」刻意不显示 `Default`：功能条只有一行，而那不是一个真档的名字。
    private func levelName(_ effective: String?, in catalog: ModelCatalog, of selection: ModelSelection?) -> String? {
        guard let effective, effective != EffortChoice.unspecifiedID, let selection,
              let reasoning = catalog.reasoning(provider: selection.provider, model: selection.model) else {
            return nil
        }
        return reasoning.efforts.first(where: { $0.id == effective })?.name
    }
}

extension ModelCatalog {

    /// 按 provider + model 找那一格推理等级；缺席 = 该模型不暴露等级选择。
    func reasoning(provider: String, model: String) -> ModelCatalogEntry.Reasoning? {
        groups?.first(where: { $0.id == provider })?
            .models.first(where: { $0.id == model })?
            .reasoning
    }
}

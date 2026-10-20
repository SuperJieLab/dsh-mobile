/**
 * 模型选择器的预构规则 —— 两个维度各自成项、换模型不带旧档、等级名只来自目录。
 *
 * 判据只喂目录与「当前显示的选择」两个输入，不碰网络、不碰视图：菜单长什么样由
 * `ModelMenu` 承载，这里断言的是**点哪一项会发什么**。
 *
 * 最后一条（O7）是源码扫描：档名只能来自目录，客户端不得内置任何一档的名字。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class ModelMenuTests: XCTestCase {

    // MARK: - 夹具

    private func level(_ id: String, _ name: String) -> ModelCatalogEntry.Reasoning.Effort {
        ModelCatalogEntry.Reasoning.Effort(id: id, name: name)
    }

    /// 两个模型：A 有低/高两档且默认高；B 有低/最高两档且默认低。
    /// B 的默认档「低」与 A 的档名不同 —— 这样「带旧档」与「带新默认」能分辨出来。
    private func catalog(twoModels: Bool = true) -> ModelCatalog {
        let a = ModelCatalogEntry(
            id: "a", name: "Model A",
            reasoning: ModelCatalogEntry.Reasoning(
                efforts: [level("low", "低"), level("high", "高")],
                defaultEffort: "high"
            )
        )
        let b = ModelCatalogEntry(
            id: "b", name: "Model B",
            reasoning: ModelCatalogEntry.Reasoning(
                efforts: [level("low", "低"), level("max", "最高")],
                defaultEffort: "low"
            )
        )
        return ModelCatalog(
            default: ModelSelection(provider: "p", model: "a"),
            groups: [ModelCatalogGroup(id: "p", name: "Provider", models: twoModels ? [a, b] : [a])],
            failures: nil
        )
    }

    private func ready(_ catalog: ModelCatalog) async -> ModelCatalogState {
        let state = ModelCatalogState(fetch: { catalog })
        await state.reload()
        return state
    }

    private func choice(_ menu: ModelMenu, model: String) -> ModelChoice? {
        menu.groups.flatMap(\.choices).first { $0.selection.model == model }
    }

    // MARK: - O1 换模型不带旧档

    /// 当前显示 A/高，点 B → 发的是 B 自己的默认档「低」，不是 A 留下的「高」。
    func testSwitchingModelCarriesTheNewModelsDefaultLevel() async {
        let state = await ready(catalog())
        let menu = state.menu(selected: ModelSelection(provider: "p", model: "a", reasoningEffort: "high"))

        guard let b = menu.flatMap({ choice($0, model: "b") }) else {
            return XCTFail("菜单里应有模型 b")
        }
        XCTAssertEqual(b.selection.reasoningEffort, "low", "换模型必须带上新模型的默认档，不能携带旧档")
        XCTAssertEqual(b.isSelected, false, "当前选中的是 a，b 不该打勾")
    }

    // MARK: - O2 没声明默认档时给「不指定」

    /// 模型有档位但没声明 `defaultEffort` → 首项是「不指定」（`effort == nil`），并且被勾中。
    func testModelWithoutDeclaredDefaultOffersUnspecifiedFirst() async {
        let entry = ModelCatalogEntry(
            id: "c", name: "Model C",
            reasoning: ModelCatalogEntry.Reasoning(
                efforts: [level("low", "低"), level("high", "高")],
                defaultEffort: nil
            )
        )
        let state = await ready(ModelCatalog(
            default: ModelSelection(provider: "p", model: "c"),
            groups: [ModelCatalogGroup(id: "p", name: "Provider", models: [entry])],
            failures: nil
        ))
        guard let menu = state.menu(selected: nil) else { return XCTFail("目录就绪应有菜单") }

        XCTAssertEqual(menu.levels.count, 3, "「不指定」+ 两个档")
        XCTAssertEqual(menu.levels.first?.label, .unspecified, "首项是「不指定」")
        XCTAssertNil(menu.levels.first?.selection.reasoningEffort, "「不指定」不带档位，交给宿主")
        XCTAssertEqual(menu.levels.first?.isSelected, true, "当前没指定档位 → 「不指定」是选中项")
        XCTAssertNil(menu.effortLabel, "没指定也没默认档 → 触发按钮不显示等级")
    }

    // MARK: - O3 没有档位的模型不提供这一级

    func testModelWithoutReasoningHasNoLevels() async {
        let plain = ModelCatalogEntry(id: "d", name: "Model D")
        let state = await ready(ModelCatalog(
            default: ModelSelection(provider: "p", model: "d"),
            groups: [ModelCatalogGroup(id: "p", name: "Provider", models: [plain])],
            failures: nil
        ))
        guard let menu = state.menu(selected: nil) else { return XCTFail("目录就绪应有菜单") }

        XCTAssertTrue(menu.levels.isEmpty, "没有 reasoning 的模型不该有等级子菜单")
        XCTAssertNil(menu.effortLabel, "也不该在触发按钮上显示等级")
    }

    // MARK: - O4 等级名三级兜底

    /// 显示值在目录里 → 用目录的名字（不是 id）。
    func testLevelNameComesFromTheCatalog() async {
        let state = await ready(catalog())
        XCTAssertEqual(
            state.effortLabel(for: ModelSelection(provider: "p", model: "a", reasoningEffort: "high")),
            "高", "名字取自目录的 name，不是 id"
        )
    }

    /// 显示值指向一个目录里已经没有的档 → 退回该模型的默认档，不把旧档名留在屏幕上。
    func testLevelNameFallsBackToTheModelsDefault() async {
        let state = await ready(catalog())
        XCTAssertEqual(
            state.effortLabel(for: ModelSelection(provider: "p", model: "a", reasoningEffort: "gone")),
            "高", "旧档不在了 → 显示默认档「高」"
        )
    }

    /// 既没有显示值也没有默认档 → 不显示（第三级是「不显示」，不是 `Default`）。
    func testLevelNameDisappearsWhenNothingIsKnown() async {
        let entry = ModelCatalogEntry(
            id: "c", name: "Model C",
            reasoning: ModelCatalogEntry.Reasoning(efforts: [level("low", "低")], defaultEffort: nil)
        )
        let state = await ready(ModelCatalog(
            default: ModelSelection(provider: "p", model: "c"),
            groups: [ModelCatalogGroup(id: "p", name: "Provider", models: [entry])],
            failures: nil
        ))
        XCTAssertNil(state.effortLabel(for: nil), "什么都不知道时只显示模型名")
    }

    // MARK: - O4b 行里的值与菜单里勾的那一项必须同源

    /// 显示值指向一个已撤下的档 → 行里显示默认档，菜单里勾的也必须是默认档那一项。
    /// 两处各算一遍时，这里会出现「行里写着高、菜单里一个都没勾」。
    func testRowValueAndCheckedLevelAgreeWhenTheShownLevelIsGone() async {
        let state = await ready(catalog())
        guard let menu = state.menu(selected: ModelSelection(provider: "p", model: "a", reasoningEffort: "gone")) else {
            return XCTFail("目录就绪应有菜单")
        }
        XCTAssertEqual(menu.effortLabel, "高", "行里退到默认档")
        XCTAssertEqual(menu.selectedLevelID, "high", "选择器的选中项也是默认档")
        XCTAssertEqual(menu.levels.filter(\.isSelected).map(\.id), ["high"], "整个菜单里只有一项被勾")
    }

    /// 模型声明了默认档时，选中项就是它；没有「不指定」这一项，也不会有两项同时被勾。
    func testExactlyOneLevelIsCheckedWhenADefaultIsDeclared() async {
        let state = await ready(catalog())
        guard let menu = state.menu(selected: nil) else { return XCTFail("目录就绪应有菜单") }
        XCTAssertEqual(menu.levels.map(\.id), ["low", "high"], "默认档已声明 → 不额外给「不指定」")
        XCTAssertEqual(menu.levels.filter(\.isSelected).map(\.id), ["high"], "只勾默认档")
        XCTAssertEqual(menu.selectedLevelID, "high")
    }

    // MARK: - O7 档名不由客户端内置

    /// 两个菜单文件的源码里不得出现具体档名字面量 —— 档名只能来自目录。
    func testMenuSourcesBakeInNoLevelNames() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                     // ios/tests/
            .deletingLastPathComponent()                     // ios/
            .appendingPathComponent("Sources/Features/SessionDetail")
        let files = [
            sources.appendingPathComponent("State/ModelMenu.swift"),
            sources.appendingPathComponent("Views/ModelPickerView.swift"),
            sources.appendingPathComponent("Views/ModelSheetView.swift"),
        ]
        // 只认带引号的字面量：注释里提到 low/high 不算内置。
        let baked = ["\"low\"", "\"high\"", "\"max\""]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in baked {
                XCTAssertFalse(text.contains(literal), "\(file.lastPathComponent) 内置了档名字面量 \(literal)")
            }
        }
    }
}

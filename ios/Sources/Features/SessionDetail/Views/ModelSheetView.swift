import SwiftUI

/// 模型选择面：第一页是模型列表，第二页（右上角齿轮进入）是当前模型的设置。
///
/// 模型是用户点功能条那一格要改的东西，等级是它的属性 —— 所以模型占第一页，等级在其后。
/// 选中模型即关闭整个面；改等级留在设置页（能立刻看到勾变，不必反复进出）。
///
/// 项与选中态由 `ModelMenu` 预构（`ModelCatalogState.menu(selected:)`）—— 本视图不拼
/// `ModelSelection`、不查目录，只把点到的选择交出去。
struct ModelSheetView: View {

    /// 目录的三面。取数与判定都在里面，这里只读 —— 由宿主持有并传进来。
    @ObservedObject var catalog: ModelCatalogState
    /// 宿主当前显示的选择；列表里打勾、设置页显示当前档都用它。
    let selected: ModelSelection?
    /// 选中一个模型或一档等级。
    let onSelect: (ModelSelection) -> Void
    /// 关掉整个面。
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("模型")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", action: onClose)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { settings } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("模型设置")
                    }
                }
        }
    }

    /// 目录的三面：等待 / 失败 + 原因 / 有内容。
    @ViewBuilder
    private var content: some View {
        switch catalog.outcome {
        case .waiting:
            ProgressView("正在加载模型…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let cause):
            VStack(spacing: 12) {
                Text(cause.line)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await catalog.reload() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            modelList
        }
    }

    /// 第一页：按 provider 分组的模型。点一行 = 选定并关闭。
    private var modelList: some View {
        List {
            if let menu = catalog.menu(selected: selected) {
                // 空目录也是成功面 —— 空列表与「没加载出来」在屏幕上会看起来一样。
                if menu.isEmpty {
                    Text(ModelCatalog.emptyNote)
                        .foregroundStyle(.secondary)
                }
                ForEach(menu.groups) { group in
                    Section(group.name) {
                        ForEach(group.choices) { choice in
                            Button {
                                onSelect(choice.selection)
                                onClose()
                            } label: {
                                row(choice.label, isSelected: choice.isSelected)
                            }
                        }
                    }
                }
                if !menu.failures.isEmpty {
                    Section("暂时不可用") {
                        ForEach(menu.failures, id: \.id) { failure in
                            // 失败隔离（上游同语义）：一个 provider 拉不到不挡其余，灰显说原因。
                            Text("\(failure.name)（\(failure.message)）")
                                .foregroundStyle(.secondary)
                        }
                        Button("重试") { Task { await catalog.reload() } }
                    }
                }
            }
        }
    }

    /// 一行模型：名字在左，选中打勾在右。
    private func row(_ text: String, isSelected: Bool) -> some View {
        HStack {
            Text(text)
                .foregroundStyle(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    /// 第二页：当前模型的设置。现在只有推理等级一项 —— 没有档位的模型给一句说明，
    /// 不给一个点不动的空菜单。
    ///
    /// 这一行用 `Picker` 而不是自己拿 `Menu` 拼 label：`Menu` 会在展开时接管 label 并施加
    /// 按下态样式，手工设的 `foregroundStyle` 与它冲突，值会被画成与背景同色（看着像整行
    /// 空了）。`Picker(.menu)` 由系统管「行 + 当前值 + 菜单」三件事，展开时值不会消失。
    private var settings: some View {
        List {
            Section {
                if let menu = catalog.menu(selected: selected), !menu.levels.isEmpty {
                    Picker("推理等级", selection: levelBinding(menu)) {
                        ForEach(menu.levels) { level in
                            Text(level.label.text).tag(level.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(menu.selectedLevelID == nil)
                } else {
                    Text("这个模型没有可调的推理等级")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("模型设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 档位选择器的绑定：读的是「已生效的那一项」（与行里显示的值同源），写回时发那一项的选择。
    private func levelBinding(_ menu: ModelMenu) -> Binding<String> {
        Binding(
            get: { menu.selectedLevelID ?? "" },
            set: { id in
                guard let level = menu.levels.first(where: { $0.id == id }) else { return }
                onSelect(level.selection)
            }
        )
    }
}

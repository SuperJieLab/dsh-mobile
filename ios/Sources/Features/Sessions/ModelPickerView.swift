import SwiftUI

/// 模型选择按钮（M7）：composer 左侧的当前模型入口，形态照上游 —— 模型选择器住在
/// 发送区旁（conversation.composer 槽位），不占消息流的位置。
///
/// 显示规则照上游（`ui-model-selection` 的显示式）：当前值 = 状态机的显示 ?? 目录默认
/// —— 服务端没说「下一轮用什么」时退到部署默认，**不猜别的**（决定 7）。目录打开时现拉
/// 一次（`loadModelCatalog`），不订阅刷新——它只在凭证 / 适配器变更时才会变，重开即新
/// （§4.7）。拉取失败的 provider 灰显并给整表重试；失败的明细不逐条重试（demo 粒度）。
struct ModelPickerView: View {
    /// 同步编排：显示值与选择动作的来源。
    @ObservedObject var sync: SessionSync

    /// 现拉一次的目录。
    @State private var catalog: ModelCatalog?
    @State private var isLoading = false

    var body: some View {
        Menu {
            menuContent
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(currentName)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .task { await reload() }
    }

    /// 按钮只显示模型名：「这是模型」由图标说了，省横向空间。
    private var currentName: String {
        (sync.displayedModel ?? catalog?.default).map { $0.model } ?? "未知"
    }

    @ViewBuilder
    private var menuContent: some View {
        if let catalog {
            ForEach(catalog.groups ?? [], id: \.id) { group in
                Section(group.name) {
                    ForEach(group.models, id: \.id) { entry in
                        Button {
                            Task { await sync.selectModel(ModelSelection(provider: group.id, model: entry.id)) }
                        } label: {
                            if sync.displayedModel?.provider == group.id,
                               sync.displayedModel?.model == entry.id {
                                Label(entry.name, systemImage: "checkmark")
                            } else {
                                Text(entry.name)
                            }
                        }
                    }
                }
            }
            if let failures = catalog.failures, !failures.isEmpty {
                Section("暂时不可用") {
                    ForEach(failures, id: \.id) { failure in
                        // 失败隔离（上游同语义）：一个 provider 拉不到不挡其余，灰显说原因。
                        Text("\(failure.name)（\(failure.message)）")
                            .foregroundStyle(.secondary)
                    }
                    Button("重试") { Task { await reload() } }
                }
            }
        } else {
            Text(isLoading ? "目录加载中…" : "目录不可用")
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        catalog = await sync.loadModelCatalog()
    }
}

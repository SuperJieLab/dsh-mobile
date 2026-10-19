import SwiftUI

/// 模型选择按钮：composer 左侧的当前模型入口，形态照上游 —— 模型选择器住在
/// 发送区旁（conversation.composer 槽位），不占消息流的位置。
///
/// 显示规则照上游（`ui-model-selection` 的显示式）：当前值 = 状态机的显示 ?? 目录默认
/// —— 服务端没说「下一轮用什么」时退到部署默认，**不猜别的**。目录打开时现拉
/// 一次（`catalog.reload()`），不订阅刷新——它只在凭证 / 适配器变更时才会变，重开即新。
/// 拉取失败的 provider 灰显并给整表重试；失败的明细不逐条重试（demo 粒度）。
///
/// **取数不在这里**（R18 期2）：「等待 / 有内容 / 失败 + 原因」三面归 `ModelCatalogState`，
/// 这个视图只发起一次取数、只读结果 —— 视图一旦持有结果，它的存活期就由框架的重建节奏决定，
/// 而重建比一次请求快得多。
struct ModelPickerView: View {
    /// 同步编排：显示值与选择动作的来源。
    @ObservedObject var sync: SessionSync

    /// 目录的三面。取数与判定都在里面，这里只读。
    @StateObject private var catalog: ModelCatalogState

    init(client: GatewayClient, sync: SessionSync) {
        self.sync = sync
        _catalog = StateObject(wrappedValue: ModelCatalogState { try await client.modelCatalog() })
    }

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
        .task { await catalog.reload() }
    }

    /// 按钮只显示模型名：「这是模型」由图标说了，省横向空间。
    private var currentName: String {
        (sync.displayedModel ?? catalogDefault).map { $0.model } ?? "未知"
    }

    /// 目录的默认值 —— 只有拿到目录时才有；没拿到就不猜。
    private var catalogDefault: ModelSelection? {
        if case .ready(let list) = catalog.outcome { return list.default }
        return nil
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
            Text(list.emptyNote)
        }
        ForEach(groups, id: \.id) { group in
            Section(group.name) {
                ForEach(group.models, id: \.id) { entry in
                    Button {
                        Task {
                            await sync.selectModel(
                                ModelSelection(provider: group.id, model: entry.id)
                            )
                        }
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

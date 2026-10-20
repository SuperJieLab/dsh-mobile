import SwiftUI

/// composer 上方那一排：网络 / 模型 / 占用。
///
/// 三格的显示值由 `ComposerStripModel` 承载（纯值，宿主算好传进来），本视图只把它们画出来。
/// 它不认识 `SessionSync` —— 认识的话，判定与取数就会一起落进视图。
///
/// 固定高度：布局的稳定性就靠它，输入框不随连接态、占用多少上下跳。键盘弹起时由宿主整条收起。
struct ComposerStrip: View {

    let model: ComposerStripModel
    /// 目录由宿主持有 —— 它也要用目录默认值算模型名，两处读的必须是同一份。
    let catalog: ModelCatalogState
    let selectedModel: ModelSelection?
    let onSelectModel: (ModelSelection) -> Void
    let onTapNetwork: () -> Void
    let onTapUsage: () -> Void

    /// 固定 32pt。三格都在这条线内，谁的内容长了就截断，不改高度。
    static let height: CGFloat = 32

    /// 网络格定宽（按最长的「连接中…」算）。不定宽的话，「直连」与「重连中…」差十来个点，
    /// 每次断连 / 恢复模型格都会横移一次。
    private static let networkWidth: CGFloat = 64
    /// 占用格定宽 —— 同理，`15%` 与 `--` 宽度不同，固定的右边界才不会让文字跳。
    private static let usageWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTapNetwork) {
                Label(model.network.text, systemImage: model.network.systemImage)
                    .font(.caption2)
                    .foregroundStyle(Self.tint(model.network.tone))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(width: Self.networkWidth, alignment: .leading)

            Spacer(minLength: 0)

            // 模型格吃剩余宽度：三项里只有它是不可压缩的自由文本。
            ModelPickerView(catalog: catalog,
                            selected: selectedModel,
                            name: model.modelName,
                            onSelect: onSelectModel)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)

            Button(action: onTapUsage) {
                Text(model.usageText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(model.usageIsEmpty ? Color.secondary : Color.primary)
            }
            .buttonStyle(.plain)
            .frame(width: Self.usageWidth, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
    }

    /// 三档颜色只在这里映射：值类型只回答「要不要被看见」，颜色是视图的事。
    /// 提成静态是为了让它可断言 —— 否则 `.attention` 改成绿色也全绿。
    static func tint(_ tone: ComposerStripModel.Tone) -> Color {
        switch tone {
        case .normal: return .secondary
        case .attention: return .orange
        }
    }
}

/// 功能条三格的显示值 —— 纯值，宿主算好，视图只画。
///
/// 三格分开：网络格单独成类型，因为它的映射是本期唯一有分歧的地方（异常靠文字、不靠图标）；
/// 其余两格只是一段文案。分开之后测试可以对每一格单独下断言。
struct ComposerStripModel: Equatable {

    let network: Network
    /// 模型格文案。宿主用「选中值 ?? 目录默认值 ?? 未知」算好 —— 那条兜底规则在
    /// `ModelCatalogState.lastKnownDefault` 上，宿主与格子读的必须是同一份。
    let modelName: String
    /// 占用格文案：有读数 `15%`，没有 `--`。
    let usageText: String
    /// 占用格是否为空 —— 空的时候灰显，点开说明原因。
    let usageIsEmpty: Bool

    enum Tone: Equatable {
        /// 常态：次要色。
        case normal
        /// 需要看一眼：橙色。断连与经中继都用它。
        case attention
    }

    struct Network: Equatable {
        let text: String
        let systemImage: String
        let tone: Tone
    }
}

extension ComposerStripModel {

    /// 三格的**唯一**映射入口 —— 视图与测试都从这里拿值。
    static func make(phase: FollowClient.Phase,
                     carrier: CarrierPath?,
                     usage: UsagePayload?,
                     modelName: String) -> ComposerStripModel {
        ComposerStripModel(network: network(phase: phase, carrier: carrier),
                           modelName: modelName,
                           usageText: usage.map { "\($0.percent)%" } ?? "--",
                           usageIsEmpty: usage == nil)
    }

    /// 网络格。`.waiting` 一律写「重连中…」而不是保留「直连」：32pt 的格里图标与颜色的
    /// 面积都太小，异常必须靠**文字**传出来，否则小屏上一眼扫过去会以为是正常态。
    /// `.ready` 而路径未知时写「已连接」—— 路径未知不等于断开。逐 case 列举，加取值时编译失败。
    ///
    /// 内部而非私有：连接详情里「状态」那一行也要它（传 `carrier: nil` 拿到的正是状态说法），
    /// 一份映射两个消费者，不另写第二份 case。
    static func network(phase: FollowClient.Phase,
                                carrier: CarrierPath?) -> Network {
        switch phase {
        case .waiting:
            return Network(text: "重连中…", systemImage: "wifi.slash", tone: .attention)
        case .connecting, .idle:
            return Network(text: "连接中…",
                           systemImage: "arrow.triangle.2.circlepath",
                           tone: .normal)
        case .ready:
            switch carrier {
            case .relay:
                // 路径文案走 `ConnectionBadge.look` —— 连接详情里那一行也读它，
                // 一份说法只写一次，改文案时不会只改到一半。
                return Network(text: ConnectionBadge.look(of: .relay).text,
                               systemImage: "personalhotspot",
                               tone: .attention)
            case .direct:
                return Network(text: ConnectionBadge.look(of: .direct).text,
                               systemImage: "arrow.left.arrow.right",
                               tone: .normal)
            case nil:
                return Network(text: "已连接", systemImage: "checkmark.circle", tone: .normal)
            }
        }
    }
}

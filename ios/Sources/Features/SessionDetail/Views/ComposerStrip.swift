import SwiftUI

/// composer 上方那一排：网络 / 模型 / 权限 / 占用。
///
/// 四格的显示值由 `ComposerStripModel` 承载（纯值，宿主算好传进来），本视图只把它们画出来。
/// 固定高度：输入框不随连接态、占用多少、权限是哪档上下跳。
struct ComposerStrip: View {

    let model: ComposerStripModel
    /// 权限那一格能点的项与当前档。空数组 = 没有可选项（格子仍在，点不开）。
    let permissionChoices: [PermissionState.Choice]
    let onSelectPermission: (PermissionState.Choice) -> Void
    /// 点模型格：打开模型面（列表 + 该模型的设置）。内容由宿主的面持有。
    let onTapModel: () -> Void
    let onTapNetwork: () -> Void
    let onTapUsage: () -> Void

    /// 固定 54pt（两行）。分两行是因为四个格横排装不下 —— 模型名按显示名算要 197pt，
    /// 而一行只剩 167pt。两行之后每行都宽松，谁都不用截断。
    static let height: CGFloat = 54

    /// 网络格定宽（按最长的「连接中…」算）。不定宽的话，「直连」与「重连中…」差十来个点，
    /// 每次断连 / 恢复模型格都会横移一次。
    private static let networkWidth: CGFloat = 64
    /// 权限格定宽 —— 按最长的「工作区内修改」六个字加一个图标算。档位名长短差得多，
    /// 不定宽会让模型格随档位横移。
    private static let permissionWidth: CGFloat = 84
    /// 占用格定宽 —— 按「图标 + 15%」算。不定宽的话 `15%` 与 `--` 宽度不同，
    /// 左列的文字会随读数横跳。
    private static let usageWidth: CGFloat = 56

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 左列：两个状态数字，左对齐。
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onTapNetwork) {
                    Label(model.network.text, systemImage: model.network.systemImage)
                        .font(.caption2)
                        .foregroundStyle(Self.tint(model.network.tone))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .frame(width: Self.networkWidth, alignment: .leading)

                Button(action: onTapUsage) {
                    // 图标与另外三格对齐 —— 四格里只有它是纯数字，没有图标会显得掉队。
                    HStack(spacing: 4) {
                        Image(systemName: "chart.pie")
                        Text(model.usageText)
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(model.usageIsEmpty ? Color.secondary.opacity(0.55) : Color.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: Self.usageWidth, alignment: .leading)
            }

            Spacer(minLength: 8)

            // 右列：两段内容，右对齐 —— 与左列的数字分列两侧。
            VStack(alignment: .trailing, spacing: 6) {
                ModelPickerView(label: model.modelLabel, onTap: onTapModel)
                    .lineLimit(1)

                // 没有权限服务的装配里这一格根本不出现（`permissionName == nil`）——
                // 留一个空位等于告诉用户「这里本来有东西」。
                if let permissionName = model.permissionName {
                    PermissionCell(label: permissionName,
                                   choices: permissionChoices,
                                   onSelect: onSelectPermission)
                        .frame(width: Self.permissionWidth, alignment: .trailing)
                }
            }
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

/// 权限那一格：一个短标签，点开是当前能选的档位。
///
/// 用 `Menu` 而不是推一个 sheet：选择型的面不该多一层（与模型格同口径）。档位名带勾，
/// 一眼看出现在是哪档。**没有可选项时置灰**（不是隐藏）—— 隐藏会让模型格横移。
private struct PermissionCell: View {
    let label: String
    let choices: [PermissionState.Choice]
    let onSelect: (PermissionState.Choice) -> Void

    var body: some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    onSelect(choice)
                } label: {
                    // 勾只标当前那一档：`isSelected` 由状态层判定，视图不比对字符串。
                    if choice.isSelected {
                        Label(choice.label.text, systemImage: "checkmark")
                    } else {
                        Text(choice.label.text)
                    }
                }
            }
        } label: {
            // 图标让这一格与上行的网络格左边缘对齐 —— 两行都从图标起笔。
            HStack(spacing: 4) {
                Image(systemName: "shield")
                Text(label)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(choices.isEmpty ? Color.secondary.opacity(0.55) : Color.secondary)
        }
        .disabled(choices.isEmpty)
    }
}

/// 功能条四格的显示值 —— 纯值，宿主算好，视图只画。
///
/// 各格分开：网络格单独成类型，因为它的映射是唯一有分歧的地方（异常靠文字、不靠图标）；
/// 其余几格只是一段文案。分开之后测试可以对每一格单独下断言。
struct ComposerStripModel: Equatable {

    let network: Network
    /// 模型名，不含等级。宿主用「选中值 ?? 目录默认值 ?? 未知」算好 —— 那条兜底规则在
    /// `ModelCatalogState.lastKnownDefault` 上，宿主与格子读的必须是同一份。
    let modelName: String
    /// 当前推理等级的名字；`nil` = 这个模型没有档位（或名字还不可知）。
    let effortName: String?
    /// 权限格的那一段：当前档的名字，宿主不知道时是 `--`。**`nil` = 这个装配没有权限服务**，
    /// 整格不画。
    let permissionName: String?
    /// 模型格最终显示的那一段：「模型名 · 等级名」，没有等级时就是模型名。
    ///
    /// 拼接放在这里而不是视图里：要不要带分隔符、带什么，是判定不是渲染；
    /// 放在 `Text(...)` 里就会有两个地方各拼一份。
    var modelLabel: String {
        effortName.map { "\(modelName) · \($0)" } ?? modelName
    }
    /// 占用格文案：有读数 `15%`，没有 `--`。
    let usageText: String
    /// 占用格是否为空 —— 空的时候灰显，点开说明原因。
    let usageIsEmpty: Bool

    enum Tone: Equatable {
        /// 常态：次要色。
        case normal
        /// 需要看一眼：橙色。断连与中继都用它。
        case attention
    }

    struct Network: Equatable {
        let text: String
        let systemImage: String
        let tone: Tone
    }
}

extension ComposerStripModel {

    /// 四格的**唯一**映射入口 —— 视图与测试都从这里拿值。
    ///
    /// `permissionName` 的默认值是 `nil`（整格不画）：漏传时宁可不显示，也不显示一个假档位。
    static func make(phase: ConnectionPhase,
                     mesh: MeshPhase,
                     carrier: CarrierPath?,
                     usage: UsagePayload?,
                     modelName: String,
                     effortName: String? = nil,
                     permissionName: String? = nil) -> ComposerStripModel {
        ComposerStripModel(network: network(phase: phase, mesh: mesh, carrier: carrier),
                           modelName: modelName,
                           effortName: effortName,
                           permissionName: permissionName,
                           usageText: usage?.percentText ?? "--",
                           usageIsEmpty: usage == nil)
    }

    /// 网络格。`.waiting` 一律写「重连中…」而不是保留「直连」：32pt 的格里图标与颜色的面积
    /// 都太小，异常必须靠**文字**传出来。`.ready` 而路径未知时写「已连接」—— 路径未知不等于
    /// **`.awaitingMesh` 的说法取决于组网为什么没就绪**：「等」只在真在注册时准确，组网已
    /// 内部而非私有：连接详情的「状态」那一行也读它（传 `carrier: nil`）。
    static func network(phase: ConnectionPhase,
                        mesh: MeshPhase?,
                        carrier: CarrierPath?) -> Network {
        switch phase {
        case .awaitingMesh:
            return awaitingMeshCell(mesh)
        case .waiting:
            return Network(text: "重连中…", systemImage: "wifi.slash", tone: .attention)
        case .connecting, .idle:
            return Network(text: "连接中…",
                           systemImage: "arrow.triangle.2.circlepath",
                           tone: .normal)
        case .ready:
            switch carrier {
            case .relay:
                return Network(text: carrierPathText(.relay),
                               systemImage: "personalhotspot",
                               tone: .attention)
            case .direct:
                return Network(text: carrierPathText(.direct),
                               systemImage: "arrow.left.arrow.right",
                               tone: .normal)
            case nil:
                return Network(text: "已连接", systemImage: "checkmark.circle", tone: .normal)
            }
        }
    }

    /// 「还没有可连的地址」这一格该说什么 —— 由组网那一步的处境定。
    ///
    /// 三档的区别是**用户该做什么**：`.connecting` 只需等；`needsSetup` 要去填地址；
    /// `failed` 要去查配置或证书。合成一句「等组网…」就把后两种说成了第一种。
    private static func awaitingMeshCell(_ mesh: MeshPhase?) -> Network {
        guard let mesh else {
            // 消费方另有地方说组网：这里只报「没连上」这个连接层事实。
            return Network(text: "未连接", systemImage: "bolt.horizontal.circle", tone: .attention)
        }
        switch mesh {
        case .needsSetup:
            return Network(text: "未配置组网", systemImage: "gearshape", tone: .attention)
        case .connecting:
            return Network(text: "等组网…",
                           systemImage: "antenna.radiowaves.left.and.right",
                           tone: .normal)
        case .ready:
            // 矛盾态：组网已就绪却还没有地址 —— 下一拍 `connect` 就会拿到。
            // 说成「连接中」而不是「等组网」：等的对象已经没有了。
            return Network(text: "连接中…",
                           systemImage: "arrow.triangle.2.circlepath",
                           tone: .normal)
        case .failed(.badKey):
            return Network(text: "组网密钥无效", systemImage: "key.slash", tone: .attention)
        case .failed(.unreachable):
            return Network(text: "组网不可达",
                           systemImage: "wifi.exclamationmark",
                           tone: .attention)
        }
    }
}

#Preview("功能条 · 单行") {
    VStack(spacing: 0) {
        Spacer()
        ComposerStrip(model: .preview,
                      permissionChoices: [],
                      onSelectPermission: { _ in },
                      onTapModel: {},
                      onTapNetwork: {},
                      onTapUsage: {})
        // 假的输入框：只为看功能条与它的相对高度。
        RoundedRectangle(cornerRadius: 20)
            .fill(.quaternary)
            .frame(height: 44)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }
}

extension ComposerStripModel {
    /// 预览用的一组值 —— 模型名取真实的长度（「DeepSeek V4.1 Flash · 高」），
    /// 短名字测不出挤压。
    static let preview = ComposerStripModel(
        network: .init(text: carrierPathText(.direct), systemImage: "wifi", tone: .normal),
        modelName: "DeepSeek V4.1 Flash",
        effortName: "高",
        permissionName: "工作区内修改",
        usageText: "23%",
        usageIsEmpty: false
    )
}

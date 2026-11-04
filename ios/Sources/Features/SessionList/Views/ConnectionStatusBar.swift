import SwiftUI

/// 列表底部的浮条：**只在有事要说时出现**，断连时整条可点。
///
/// 它取代了两处东西：左上角那个不能点的连接徽章（常态空白，却占着一个按钮位），
/// 以及页脚那句「N 个会话」（每个组的标题行各自报了数，再说一次是重复）。
///
/// 常态**整条不出现**：直连、有数据的时候没有任何事需要用户知道，一条常驻的
/// 「一切正常」只是在替屏幕占地方。
struct ConnectionStatusBar: View {
    let model: ConnectionStatusBarModel
    /// 重拉一次列表。只在 `model.canRetry` 时被调用。
    let onRetry: () -> Void

    var body: some View {
        Group {
            if model.canRetry {
                // 整条都是按钮：断连时用户的手指不会正好落在「重试」两个字上。
                Button(action: onRetry) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .tint(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.orange.opacity(0.3), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: model.systemImage)
            Text(model.text)
                .lineLimit(1)
            // 没有动作时右侧什么都不放 —— 一个点了没事发生的词，比没有更糟。
            if model.canRetry {
                Text("重试")
                    .fontWeight(.medium)
                    .padding(.leading, 6)
            }
        }
    }
}

/// 浮条的显示值 —— 纯值，宿主算好，视图只画。
///
/// 不带档位字段：这条浮条只在「值得看一眼」的时候存在，所以它只有一种样子。
struct ConnectionStatusBarModel: Equatable {
    let text: String
    let systemImage: String
    /// 断连时为真：右侧出现「重试」，整条可点。中继只是告知，不给动作。
    let canRetry: Bool
}

extension ConnectionStatusBarModel {

    /// 唯一的映射入口 —— 视图与判据都从这里拿值。
    ///
    /// @param carrier - 组网路径；未就绪时是 `nil`。
    /// @param failure - 上一次读取列表的失败说明；`nil` = 没失败。
    /// @returns `nil` 表示这一条**整条不该出现**。
    static func make(carrier: CarrierPath?, failure: String?) -> ConnectionStatusBarModel? {
        // 断连优先：那一刻路径既不可知也不重要，用户要知道的是「现在没连上」。
        if failure != nil {
            return ConnectionStatusBarModel(text: "已断开 · 重连中",
                                            systemImage: "wifi.slash",
                                            canRetry: true)
        }
        guard let carrier else { return nil }
        switch carrier {
        case .direct:
            // 常态。说「直连」等于告诉用户「一切照常」，而屏幕上的会话已经在说这件事了。
            return nil
        case .relay:
            // 绕行是有代价的（多一跳），用户该知道慢是为什么。
            return ConnectionStatusBarModel(text: "\(carrierPathText(carrier)) · 较慢",
                                            systemImage: "personalhotspot",
                                            canRetry: false)
        }
    }
}

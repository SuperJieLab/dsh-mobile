import SwiftUI

/// 连接态指示器 —— 上游 `connecting` / `disconnected` 指示器的复现。
/// 两半语义照抄上游：断连要诚实（如实标注、旧内容照常展示、不清屏不弹错误页）；短尝试要
/// 状态由调用方自己映射后传入，本组件不知道领域：列表域看刷新请求成败。
struct ConnectionBadge: View {
    enum Status: Equatable {
        /// 数据源可达 —— 不显示。
        case hidden
        /// 正在连接（请求在途 / 握手中）。
        case connecting
        /// 已断开（上次请求失败 / 退避重连等待中）。
        case offline
    }

    /// 到网关对端的连接方式：running 时显示一行「直连 / 中继」。
    /// 取值用连接域的 `CarrierPath`，不在这里另声明 —— 同值同义的两个枚举只能靠手写映射，
    /// 而那种映射加第三个取值时会静默归到 else。
    let state: Status
    var meshPath: CarrierPath?

    /// 合成的逐成员初始化器会带上私有的 `@State` 而不可见，显式给一个。
    init(state: Status, meshPath: CarrierPath? = nil) {
        self.state = state
        self.meshPath = meshPath
    }

    /// 指示器一旦显示，至少停留此时长 —— 照抄上游的最短显示时长。
    private static let minDisplaySeconds: TimeInterval = 2

    /// 实际渲染的状态。与 `state` 的差值就是防闪烁窗口：
    /// `state` 已回 hidden 而未停满最短时长时保留旧值。
    @State private var shown: Status?
    @State private var shownAt = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 组网路径一行：独立于断连指示器 —— 已入网时它常在，
            // 断连语义仍由下面的防闪烁窗口管。
            if let meshPath {
                let look = Self.look(of: meshPath)
                Label(look.text, systemImage: look.icon)
                    .font(.caption2)
                    .foregroundStyle(look.tint)
            }
            if let shown {
                Label {
                    Text(caption(shown))
                } icon: {
                    Image(systemName: icon(shown))
                }
                .font(.caption)
                .foregroundStyle(tint(shown))
            }
        }
        .task(id: state) {
            if state != .hidden {
                shown = state
                shownAt = Date()
            } else {
                // 数据源已恢复；显示不满最短时长就等满再收 —— 短暂抖动不闪烁。
                let elapsed = Date().timeIntervalSince(shownAt)
                if elapsed < Self.minDisplaySeconds {
                    try? await Task.sleep(nanoseconds: UInt64((Self.minDisplaySeconds - elapsed) * 1_000_000_000))
                }
                // 睡完 `state` 若又变了，`.task(id:)` 会被重启并覆盖 `shown`，无需在此判断。
                shown = nil
            }
        }
    }

    private func caption(_ state: Status) -> String {
        switch state {
        case .connecting: return "连接中…"
        case .offline: return "已断开 · 重连中"
        case .hidden: return ""
        }
    }

    private func icon(_ state: Status) -> String {
        switch state {
        case .connecting: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .hidden: return ""
        }
    }

    /// 断连用橙色提醒、连接中用次要色 —— 与 `caption` / `icon` 一样逐 case 列举，
    /// `Status` 加取值时三处都会编译失败。
    private func tint(_ state: Status) -> Color {
        switch state {
        case .connecting: return .secondary
        case .offline: return .orange
        case .hidden: return .secondary
        }
    }
}

// MARK: - 各域的状态映射

extension ConnectionBadge.Status {
    /// 列表域：刷新在途 = 连接中；上次刷新失败 = 已断开（旧列表照常可读）。
    /// **详情域不吃这个组件**：它那三格（网络 / 模型 / 占用）由 `ComposerStrip` 画。
    init(isLoading: Bool, lastFailure: String?) {
        if lastFailure != nil {
            self = .offline
        } else if isLoading {
            self = .connecting
        } else {
            self = .hidden
        }
    }

}

// MARK: - 组网路径那一行的显示

extension ConnectionBadge {

    /// 图标与颜色。文案不在这里 —— 三块屏都说这件事，那份住 `carrierPathText`。
    ///
    /// `switch` 逐个列举，**不用 `default`**：`CarrierPath` 加第三个取值时这里编译失败，
    /// 而不是静默落到 else。
    static func look(of path: CarrierPath) -> (text: String, icon: String, tint: Color) {
        let icon: String
        let tint: Color
        switch path {
        case .direct:
            icon = "arrow.left.arrow.right"
            tint = .secondary
        case .relay:
            icon = "personalhotspot"
            tint = .orange
        }
        return (carrierPathText(path), icon, tint)
    }
}

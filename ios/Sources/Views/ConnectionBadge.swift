import SwiftUI

/// 连接态指示器（M3）—— 上游 Web UI `connecting` / `disconnected` 指示器的复现
/// （`ui-settings-general/src/client/SettingsRoot.tsx:203-228`）。
///
/// 两半语义照抄上游：断连要诚实（正在连接 / 已断开如实标注，旧内容照常展示，
/// 不清屏不弹错误页）；短尝试要防闪烁（指示器一旦显示，至少停留
/// `minDisplaySeconds`，期间恢复也不会一闪而过）。
///
/// 状态由各屏自己映射后传入，本组件不知道列表与详情的区别：
/// - 列表域：刷新请求成败（`isLoading` / `failure`）；
/// - 详情域：跟随流的连接阶段（`SessionSync.connectionPhase`）。
struct ConnectionBadge: View {
    enum Status: Equatable {
        /// 数据源可达 —— 不显示。
        case hidden
        /// 正在连接（请求在途 / 握手中）。
        case connecting
        /// 已断开（上次请求失败 / 退避重连等待中）。
        case offline
    }

    let state: Status

    /// 合成的逐成员初始化器会带上私有的 `@State` 而不可见，显式给一个。
    init(state: Status) {
        self.state = state
    }

    /// 指示器一旦显示，至少停留此时长 —— 照抄上游的最短显示时长。
    private static let minDisplaySeconds: TimeInterval = 2

    /// 实际渲染的状态。与 `state` 的差值就是防闪烁窗口：`state` 已回 hidden、
    /// 显示还没停满最短时长时，这里暂时保留旧值。
    @State private var shown: Status?
    @State private var shownAt = Date.distantPast

    var body: some View {
        Group {
            if let shown {
                Label {
                    Text(caption(shown))
                } icon: {
                    Image(systemName: icon(shown))
                }
                .font(.caption)
                .foregroundStyle(shown == .offline ? Color.orange : Color.secondary)
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
}

// MARK: - 各域的状态映射

extension ConnectionBadge.Status {
    /// 列表域：刷新在途 = 连接中；上次刷新失败 = 已断开（旧列表照常可读）。
    init(isLoading: Bool, lastFailure: String?) {
        if lastFailure != nil {
            self = .offline
        } else if isLoading {
            self = .connecting
        } else {
            self = .hidden
        }
    }

    /// 详情域：跟随流的连接阶段直译。`idle` 不显示 —— 首次加载有既有的占位 UI。
    init(followPhase: FollowClient.Phase) {
        switch followPhase {
        case .idle, .ready:
            self = .hidden
        case .connecting:
            self = .connecting
        case .waiting:
            self = .offline
        }
    }
}

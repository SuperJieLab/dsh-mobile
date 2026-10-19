import SwiftUI

/// 连接态指示器 —— 上游 `connecting` / `disconnected` 指示器的复现。
///
/// 两半语义照抄上游：断连要诚实（如实标注、旧内容照常展示、不清屏不弹错误页）；短尝试要
/// 防闪烁（一旦显示至少停留 `minDisplaySeconds`，期间恢复也不一闪而过）。
///
/// 状态由各屏自己映射后传入，本组件不知道列表与详情的区别：列表域看刷新请求成败
/// （`isLoading` / `failure`），详情域看订阅流连接阶段（`SessionSync.connectionPhase`）。
/// 消费方两处：`SessionListView`（列表域）与 `SessionDetailView`（详情域）。
struct ConnectionBadge: View {
    enum Status: Equatable {
        /// 数据源可达 —— 不显示。
        case hidden
        /// 正在连接（请求在途 / 握手中）。
        case connecting
        /// 已断开（上次请求失败 / 退避重连等待中）。
        case offline
    }

    /// 到网关对端的连接方式：running 时显示一行「直连 / 经中继」。
    ///
    /// 取值类型用连接域的 `CarrierPath`，不在这里另声明一份 —— 同值同义的两个枚举只能靠
    /// 手写映射相连，而那类映射（`x == .direct ? .direct : .relay`）加第三个取值时会静默
    /// 归到 else。本组件本来就在认识 Core 的类型（下面的 `Status.init(followPhase:)`
    /// 吃 `FollowClient.Phase`），所以这里不是新增耦合。
    let state: Status
    var meshPath: CarrierPath? = nil

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
            // 断连语义仍由上面的防闪烁窗口管。
            if let meshPath {
                let look = Self.look(of: meshPath)
                Label(look.text, systemImage: look.icon)
                    .font(.caption2)
                    .foregroundStyle(look.tint)
            }
            Group {
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
    ///
    /// **为什么不与详情域的入口合一**：两屏能拿到的信号本来就不同 —— 列表只有
    /// 一元刷新的 `isLoading` / `lastFailure`，详情才有订阅流的相位（`idle` / `connecting` /
    /// `ready` / `waiting`）。合成一个入口只能让调用方给另一半传 `nil`，那等于把「这一屏没有这个
    /// 信号」伪装成「这个信号现在是空值」。
    init(isLoading: Bool, lastFailure: String?) {
        if lastFailure != nil {
            self = .offline
        } else if isLoading {
            self = .connecting
        } else {
            self = .hidden
        }
    }

    /// 详情域：订阅流的连接阶段直译。`idle` 不显示 —— 首次加载有既有的占位 UI。
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

// MARK: - 组网路径那一行的显示

extension ConnectionBadge {

    /// 连接方式的三件套：文案、图标、颜色。
    ///
    /// `switch` 逐个列举，**不用 `default`**：`CarrierPath` 加第三个取值时这里编译失败，
    /// 而不是静默落到 else（三元写法正是那样吞掉新取值的）。
    static func look(of path: CarrierPath) -> (text: String, icon: String, tint: Color) {
        switch path {
        case .direct:
            return ("直连", "arrow.left.arrow.right", Color.secondary)
        case .relay:
            return ("经中继", "personalhotspot", Color.orange)
        }
    }
}

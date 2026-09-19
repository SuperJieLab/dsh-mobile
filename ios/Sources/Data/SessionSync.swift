import Combine
import Foundation

/// 一个会话的同步编排：把「取窗口 / 追新增 / 往回翻」三件事接到状态机上。
///
/// 状态机（`SessionMirror`）只管判定，这里管调用顺序与失败收场，界面只管显示。
/// 三处纪律落在这里：
/// - **单飞**：同一会话同时只有一个同步过程（`isSyncing`）。
/// - **拉完为止**：追新增时一块装不下就接着要，直到服务端说没有更多。
/// - **先窗口后增量**：打开会话必须先向服务端要一个最新的窗口，再从这里往后追 ——
///   这样**不需要跨会话记住任何位置**，冷启动、重启、跑了一夜回来，行为都一样。
///
/// 镜像只在内存里（见 `SessionMirror` 的说明）：没有任何位置或内容落盘。
///
/// 用 `ObservableObject` 而不是更新的 `@Observable` 宏：后者要跑一个进程外的宏插件，
/// 而本项目的验证环境不允许 —— **能被本地编译验证，比写法新更重要**。
@MainActor
final class SessionSync: ObservableObject {

    /// 状态行要说的事。**重置与失败必须说得出来** —— 那是用户唯一能察觉异常的地方。
    enum Status: Equatable {
        case idle
        case syncing
        case done(added: Int, recovered: Bool)
        case failed(String)
    }

    /// 屏幕上要画的消息。
    @Published private(set) var messages: [DisplayMessage] = []
    /// 视图里的事件条数（消息只是其中一部分）。
    @Published private(set) var eventCount = 0
    /// 还能往回翻吗。为真时界面给出入口。
    @Published private(set) var hasOlder = false
    @Published private(set) var status: Status = .idle

    private let client: GatewayClient
    private let sessionId: String
    /// 内存里的镜像。视图重建时会新建一个 `SessionSync`，于是窗口重取一次 ——
    /// 这是刻意的：窗口是服务端此刻给的，比任何本地残留都可信。
    private var mirror = SessionMirror()
    private var isSyncing = false

    init(client: GatewayClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
    }

    /// 同步一次：镜像空着就先取一个窗口，然后从末尾追新增到最新。
    ///
    /// 幂等 —— 已经是最新时它退化成一次空增量请求，这正是它的正常形态。
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        status = .syncing

        var added = 0
        var recovered = false

        // 打开会话：手里什么都没有时，先向服务端要一个最新的窗口。
        if mirror.isEmpty {
            switch await openLatest() {
            case .merged(let count):
                added += count
            case .caughtUp:
                break
            case .resetRequired:
                // 窗口本身对不上，没有比它更早的状态可退。
                mirror.reset()
                recovered = true
            case .refused(let code):
                status = .failed("服务端拒绝了这次读取：\(code)")
                refreshView()
                return
            case .failed:
                status = .failed("没连上网关 —— 这一屏还是空的。")
                refreshView()
                return
            }
        }

        // 追新增：从镜像的末尾一直拉到服务端没有更多。
        while true {
            guard mirror.beginRequest() else { break }
            let outcome = await fetchSnapshot()
            let more = hasMore(in: outcome)

            switch mirror.apply(outcome) {
            case .merged(let count):
                added += count

            case .caughtUp:
                break

            case .resetRequired(let reason):
                // 重置只做一次：若重置之后服务端又要求重置，那说明继续拉也不会收敛，
                // 停下来把情况说清楚，比无限重试好。
                guard !recovered else {
                    status = .failed("服务端连续要求重新同步（\(label(reason))）—— 已停止重试。")
                    refreshView()
                    return
                }
                recovered = true
                mirror.reset()
                // 位置已作废，没有内容可续。下一次同步会以「取窗口」的形态重来。
                status = .done(added: added, recovered: true)
                refreshView()
                return

            case .refused(let code):
                status = .failed("服务端拒绝了这次同步：\(code)")
                refreshView()
                return

            case .failed:
                // 传输失败：视图保持原样（状态机保证），只把状态说清楚。
                status = .failed("没连上网关 —— 手机上看到的仍是上一次同步的内容。")
                refreshView()
                return
            }

            if !more { break }
        }

        status = .done(added: added, recovered: recovered)
        refreshView()
    }

    /// 往回翻一段更早的历史。已经翻到日志开头时什么也不做。
    func loadOlder() async {
        guard !isSyncing, mirror.hasOlder else { return }
        isSyncing = true
        defer { isSyncing = false }
        status = .syncing

        guard mirror.beginRequest() else { return }

        let verdict: Verdict
        do {
            let page = try await client.page(sessionId: sessionId, beforeSeq: mirror.pageStart)
            verdict = mirror.prepend(window(page))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error {
                verdict = .refused(code: failure.code)
            } else {
                verdict = .failed
            }
        } catch {
            verdict = .failed
        }

        switch verdict {
        case .merged(let count):
            status = .done(added: count, recovered: false)
        case .caughtUp:
            status = .done(added: 0, recovered: false)
        case .resetRequired:
            // 这一段接不上当前视图的起点 —— 与其留一个看不见的缺口，不如清空重来。
            mirror.reset()
            status = .failed("更早的历史接不上这一段 —— 已清空，下拉可重新同步。")
        case .refused(let code):
            status = .failed("服务端拒绝了这次读取：\(code)")
        case .failed:
            status = .failed("没连上网关 —— 未能加载更早的消息。")
        }

        refreshView()
    }

    // MARK: - 一次请求

    /// 取最新的一个窗口（打开会话）。
    private func openLatest() async -> Verdict {
        guard mirror.beginRequest() else { return .caughtUp }
        do {
            let page = try await client.page(sessionId: sessionId)
            return mirror.open(with: window(page))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error { return .refused(code: failure.code) }
            return .failed
        } catch {
            return .failed
        }
    }

    /// 从镜像的末尾往前拉一块。
    private func fetchSnapshot() async -> Outcome {
        do {
            let snapshot = try await client.snapshot(sessionId: sessionId, since: mirror.cursor)
            return .received(Snapshot(
                asOfSeq: snapshot.asOfSeq,
                hasMore: snapshot.hasMore,
                events: snapshot.events
            ))
        } catch let error as GatewayClientError {
            if case .refused(let failure) = error {
                return .refused(Refusal(code: failure.code, message: failure.message))
            }
            return .transportFailed
        } catch {
            return .transportFailed
        }
    }

    private func hasMore(in outcome: Outcome) -> Bool {
        if case .received(let snapshot) = outcome { return snapshot.hasMore }
        return false
    }

    /// 网络层的窗口 → 状态机的窗口。两者形状相同：一个是「服务端的回应」，
    /// 一个是「状态机的输入」，各自跟着自己的层走。
    private func window(_ page: SessionPage) -> Window {
        Window(
            pageStart: page.pageStart,
            asOfSeq: page.asOfSeq,
            hasOlder: page.hasOlder,
            events: page.events
        )
    }

    /// 刷新界面可见的部分。状态机是唯一的事实来源。
    private func refreshView() {
        messages = mirror.events.compactMap(\.displayMessage)
        eventCount = mirror.events.count
        hasOlder = mirror.hasOlder
    }

    /// 重置理由的人话说法。这类文案属于界面，不属于状态机。
    private func label(_ reason: ResetReason) -> String {
        switch reason {
        case .gap: return "中间有事件没拿到"
        case .waterMarkWentBack: return "服务端给的位置比本地还靠前"
        case .cursorVoid: return "本地记的位置在 Mac 上不存在了"
        }
    }
}

extension SessionSync.Status {
    /// 状态行的一句话。
    var line: String {
        switch self {
        case .idle:
            return "尚未同步"
        case .syncing:
            return "正在同步…"
        case .done(let added, let recovered):
            let prefix = recovered ? "已重新同步" : "已是最新"
            return added == 0 ? prefix : "\(prefix)，新增 \(added) 条"
        case .failed(let detail):
            return detail
        }
    }
}

import Foundation
import MetricKit

/// MetricKit 的订阅者：系统把性能与诊断 payload 交过来，这里落盘并留一行摘要。
///
/// **不自建卡死检测**：MetricKit 连 watchdog 杀进程（`0x8badf00d`）都能区分，而自己写的
/// 那个只能覆盖主线程 —— 两者不是同一个问题的两种做法，前者是后者的超集。
///
/// 模拟器上永远收不到 payload（系统不投递），所以能验的只有「收到之后」那一段：Xcode 的
/// `Debug > Simulate MetricKit Payloads` 会投一份样例进来，走的就是下面这两个回调。
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {

    private let store: TelemetryStore
    /// 注册口。默认就是真的 `MXMetricManager`；可注入是为了让「只注册一次」这条
    /// 能被判据看见 —— 它守的是启动编排重复调 `start()` 时的行为。
    private let register: (MXMetricManagerSubscriber) -> Void
    /// 注册幂等：`start()` 被调两次不该收两份。
    private var started = false

    init(
        store: TelemetryStore,
        register: @escaping (MXMetricManagerSubscriber) -> Void = { MXMetricManager.shared.add($0) }
    ) {
        self.store = store
        self.register = register
        super.init()
    }

    /// 注册订阅。**在启动编排的最前面调** —— 它不依赖任何别的服务，而晚注册会让这一轮
    /// 已经投递的 payload 等下一次。
    func start() {
        guard !started else { return }
        started = true
        register(self)
        Log.info(Log.Module.telemetry, "MetricKit subscriber attached")
    }

    // MARK: - MXMetricManagerSubscriber

    /// 每天一份的性能指标（启动、卡顿、内存、磁盘写入、能耗都在里面）。
    func didReceive(_ payloads: [MXMetricPayload]) {
        receive(payloads.map { $0.jsonRepresentation() }, kind: .metrics, label: "metric")
    }

    /// 崩溃、卡死、CPU 异常等诊断。24 小时延迟，且要用户打开「共享分析」才收得到。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.reduce(0) { $0 + ($1.crashDiagnostics?.count ?? 0) }
        let hangs = payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) }
        receive(payloads.map { $0.jsonRepresentation() }, kind: .diagnostics, label: "diagnostic")
        // 诊断里只有这两类值得单独报一行：崩溃与卡死是「用户会因此离开」的那两种，
        // 其余（CPU 异常、磁盘写入过量）打开 JSON 才看得懂，不适合进日志。
        if crashes > 0 || hangs > 0 {
            Log.warn(Log.Module.telemetry, "diagnostics received",
                     ["crashes": String(crashes), "hangs": String(hangs)])
        }
    }

    // MARK: - 落盘

    private func receive(_ items: [Data], kind: TelemetryStore.Kind, label: String) {
        guard !items.isEmpty else { return }
        var saved = 0
        for data in items {
            do {
                try store.save(data, kind: kind, at: Date())
                saved += 1
            } catch {
                Log.warn(Log.Module.telemetry, "could not save payload",
                         ["kind": label, "error": String(describing: error)])
            }
        }
        Log.info(Log.Module.telemetry, "payloads received",
                 ["kind": label, "saved": String(saved), "total": String(items.count)])
    }
}

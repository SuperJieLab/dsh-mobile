import Foundation

/// 唯一日志出口：ISO8601 UTC 毫秒时间戳 + [dsh] + [级别][模块]，stderr 直写（Xcode 控制台可见，
/// 与 tsnet Go 日志同通道对照）。`[dsh]` 是全局过滤标签：控制台噪音（libnetwork 的
/// "cannot add handler"、OS 自言自语）和 Go 日志都没有它，按它过滤只留我们的行。
enum Log {

    /// 模块标签集中在此登记，调用点不允许写散字符串；新场景需要新标签时先来这里加。
    enum Module {
        static let app = "app"
        static let mesh = "mesh"
        static let gateway = "gateway"
        static let pairing = "pairing"
        static let session = "session"
    }

    /// debug 级默认静默，DSH_LOG_DEBUG=1 打开。可变（而非 private let）是为测试能覆写；
    /// 默认值照旧从环境读。
    static var debugEnabled: Bool = ProcessInfo.processInfo.environment["DSH_LOG_DEBUG"] == "1"

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let lock = NSLock()

    static func debug(_ module: String, _ message: String) { write("debug", module, message) }
    static func info(_ module: String, _ message: String) { write("info", module, message) }
    static func warn(_ module: String, _ message: String) { write("warn", module, message) }
    static func error(_ module: String, _ message: String) { write("error", module, message) }

    private static func write(_ level: String, _ module: String, _ message: String) {
        if level == "debug" && !debugEnabled { return }
        writeRaw("\(formatter.string(from: Date())) [dsh][\(level)][\(module)] \(message)\n")
    }

    private static func writeRaw(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - 性能记录（R8 期1）

    /// perf 行的去向。默认 stderr；只有测试会替换它 —— 与网关 perf.ts 的
    /// `setPerfSink` 同构（同一出口纪律下的同一后门）。
    static var perfSink: (String) -> Void = { line in writeRaw(line) }

    /// 记一条性能记录：与文本行同拼写（`ISO8601 [dsh][perf][模块] {json}`）、同门控，
    /// 载荷是 JSON，供期2 扫参脚本消费。门控关时什么都不写。
    static func perf(_ module: String, _ record: PerfRecord) {
        guard debugEnabled, let json = record.jsonString else { return }
        perfSink("\(formatter.string(from: Date())) [dsh][perf][\(module)] \(json)\n")
    }
}

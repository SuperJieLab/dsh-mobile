import Foundation

/// 唯一日志出口：ISO8601 UTC 毫秒时间戳 + [dsh] + [级别][模块]，stderr 直写（Xcode 控制台可见，
/// 与 tsnet Go 日志同通道对照）。`[dsh]` 是全局过滤标签：控制台噪音（libnetwork 的
/// "cannot add handler"、OS 自言自语）和 Go 日志都没有它，按它过滤只留我们的行。
/// 规范见 dev/CONVENTIONS.md §2。
enum Log {

    /// 模块标签集中在此登记，调用点不允许写散字符串；新场景需要新标签时先来这里加。
    enum Module {
        static let app = "app"
        static let mesh = "mesh"
        static let gateway = "gateway"
        static let pairing = "pairing"
        static let session = "session"
    }

    /// debug 级默认静默，DSH_LOG_DEBUG=1 打开。
    private static let debugEnabled = ProcessInfo.processInfo.environment["DSH_LOG_DEBUG"] == "1"

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
        let line = "\(formatter.string(from: Date())) [dsh][\(level)][\(module)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }
}

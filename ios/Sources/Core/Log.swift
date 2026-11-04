import Foundation

/// 唯一日志出口：本机时间（带显式偏移）+ [dsh] + [级别][模块]，stderr 直写（Xcode 控制台可见，
/// 与 tsnet Go 日志同通道对照）。`[dsh]` 是全局过滤标签：控制台噪音（libnetwork 的
/// "cannot add handler"、OS 自言自语）和 Go 日志都没有它，按它过滤只留我们的行。
/// 时间戳的形状在 `LogTimestamp`（两端各一份实现、同一组样本），这里只负责行与去向。
enum Log {

    /// 模块标签集中在此登记，调用点不允许写散字符串；新场景需要新标签时先来这里加。
    enum Module {
        static let mesh = "mesh"
        static let gateway = "gateway"
        static let session = "session"
        /// 工作空间的写链路：建 / 删 / 在其中建会话。与 `session` 分开是因为
        /// 这几个动作都不可逆或难观察（删注册、落在哪个目录），排障时要能单独拎出来。
        static let workspace = "workspace"
        /// 端上遥测：MetricKit 的投递与落盘。与 `session` 分开是因为它按天发生，
        /// 混进会话日志里会把它淹掉。
        static let telemetry = "telemetry"
    }

    /// debug 级默认静默，DSH_LOG_DEBUG=1 打开。可变（而非 private let）是为测试能覆写；
    /// 默认值照旧从环境读。
    static var debugEnabled: Bool = ProcessInfo.processInfo.environment["DSH_LOG_DEBUG"] == "1"

    private static let lock = NSLock()

    /// 落盘口。`nil` = 只写 stderr（测试与未安装时）。装它要在启动最早期 ——
    /// 晚装的每一行都只活在控制台里，而控制台在断开之后什么都没有。
    private static var fileSink: ((String) -> Void)?

    /// 装上落盘。幂等：装第二次只是换掉同一个口；传 `nil` 卸掉（判据要能还原现场）。
    static func installFileLog(_ file: LogFile?) {
        lock.lock()
        defer { lock.unlock() }
        fileSink = file?.append
    }

    /// 动态值走这里，正文只写固定短语。
    ///
    /// 为什么：正文里插值的行只能正则取，于是「按 op 统计失败率」做不到 ——
    /// 而那是日志存在的第二个理由。字段化之后同一个 key 在任何模块里都是同一个意思。
    /// 值只收字符串：日志是给人读的，嵌一个对象进去只会让 grep 变成猜。
    static func debug(_ module: String, _ message: String, _ fields: [String: String] = [:]) {
        write("debug", module, message, fields)
    }
    static func info(_ module: String, _ message: String, _ fields: [String: String] = [:]) {
        write("info", module, message, fields)
    }
    static func warn(_ module: String, _ message: String, _ fields: [String: String] = [:]) {
        write("warn", module, message, fields)
    }
    static func error(_ module: String, _ message: String, _ fields: [String: String] = [:]) {
        write("error", module, message, fields)
    }

    private static func write(
        _ level: String, _ module: String, _ message: String, _ fields: [String: String]
    ) {
        if level == "debug" && !debugEnabled { return }
        let stamp = LogTimestamp.string(from: Date())
        let tail = formatFields(fields)
        writeRaw("\(stamp) [dsh][\(level)][\(module)]\(RpcTrace.lineMarker) \(message)\(tail)\n")
    }

    /// 把字段拼成 ` key=value key2=value2`，按 key 排序。
    ///
    /// 排序不是洁癖：同一行在不同次跑里字段顺序不同的话，「这行变了没」每次都要重新看。
    /// 含空格或等号的值用引号包起来 —— 否则 `msg=a b` 会让 grep 的人以为有两个字段。
    static func formatFields(_ fields: [String: String]) -> String {
        guard !fields.isEmpty else { return "" }
        let parts = fields.keys.sorted().map { key -> String in
            let raw = fields[key] ?? ""
            let needsQuote = raw.contains(" ") || raw.contains("=") || raw.contains("\"")
            guard needsQuote else { return "\(key)=\(raw)" }
            let escaped = raw
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\(key)=\"\(escaped)\""
        }
        return " " + parts.joined(separator: " ")
    }

    private static func writeRaw(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        // 同一个出口两处去向：控制台给人看，文件给「断开之后」看。
        fileSink?(line)
    }

    // MARK: - 性能记录

    /// perf 行的去向。默认 stderr；只有测试会替换它 —— 与网关 perf.ts 的
    /// `setPerfSink` 同构（同一出口纪律下的同一后门）。
    static var perfSink: (String) -> Void = { line in writeRaw(line) }

    /// 记一条性能记录：与文本行同拼写（`<本机时间带偏移> [dsh][perf][模块] {json}`）、同门控，
    /// 载荷是 JSON，供分析脚本消费。门控关时什么都不写。
    static func perf(_ module: String, _ record: PerfRecord) {
        guard debugEnabled, let json = record.jsonString else { return }
        perfSink("\(LogTimestamp.string(from: Date())) [dsh][perf][\(module)] \(json)\n")
    }
}

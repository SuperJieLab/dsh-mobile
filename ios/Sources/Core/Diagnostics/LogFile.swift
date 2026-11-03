import Foundation

/// 日志的落盘：`stderr` 之外多一份文件，按大小轮转。
///
/// **每行都写，不批量**。被杀的那一刻正是什么都没有的那一刻，而崩溃前那几行正是要看的；
/// 批量写省下的 syscall 换不来「最后 19 行丢了」的可接受性。日志一天几千行，一次追加
/// 是微秒级，而 `stderr` 本来就每行一次系统调用。
///
/// 轮转保留**后半**而不是清空：清空之后，「上一次跑发生了什么」就只剩一句「文件刚被清」。
final class LogFile {

    let url: URL
    /// 超过它就轮转。默认 1 MB —— 大约一万行，够覆盖「上一次跑」且不至于让导出变慢。
    private let maxBytes: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    /// 已写入的字节数。不用每次 `stat`：那是每行一次系统调用，而这里只需要一个近似值。
    private var written = 0

    init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.intValue
        written = existing ?? 0
    }

    /// 追加一行。任何 I/O 失败都静默 —— 日志写不下去不该让 App 崩。
    func append(_ line: String) {
        let data = Data(line.utf8)
        lock.lock()
        defer { lock.unlock() }

        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            written += data.count
        } catch {
            // 句柄可能已失效（文件被外部删掉、磁盘满）。丢掉它，下一行重开一次。
            try? handle.close()
            self.handle = nil
            return
        }
        if written > maxBytes { rotate() }
    }

    /// 最近若干字节的文本。切点落在行中间时，从第一个换行之后开始 —— 半行日志读起来是噪音。
    func tail(maxBytes: Int = 200_000) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return "" }
        guard data.count > maxBytes else { return String(decoding: data, as: UTF8.self) }

        let slice = data.suffix(maxBytes)
        guard let newline = slice.firstIndex(of: 0x0A) else {
            return String(decoding: slice, as: UTF8.self)
        }
        return String(decoding: slice[slice.index(after: newline)...], as: UTF8.self)
    }

    /// 清空。测试与「用户主动清掉」用。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
        written = 0
        try? FileManager.default.removeItem(at: url)
    }

    /// 保留后半，切点对齐到行首。
    private func rotate() {
        guard let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(maxBytes / 2)
        let aligned = keep.firstIndex(of: 0x0A).map { keep[keep.index(after: $0)...] } ?? keep
        try? handle?.close()
        handle = nil
        try? Data(aligned).write(to: url)
        written = aligned.count
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}

extension LogFile {

    /// 默认落点：`Application Support/Logs/current.log`。
    /// 放 `Application Support` 而不是 `Caches`：后者会被系统在磁盘紧张时删掉，
    /// 而「上一次跑发生了什么」正是磁盘紧张时最想知道的事。
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("current.log")
    }
}

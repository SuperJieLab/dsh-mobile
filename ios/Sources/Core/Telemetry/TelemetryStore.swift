import Foundation

/// 端上遥测的落盘：把 MetricKit 交来的 payload 原文按类别留最近若干份。
///
/// 为什么留原文而不是先解析成我们自己的形状：payload 的字段随系统版本增减，解析一遍
/// 等于把系统的版本差异接进代码里。原文留着，将来要什么字段再解；摘要那一行是给人
/// 看的，原文是给「以后想知道更多」留的。
struct TelemetryStore {

    /// 两类 payload。分文件是因为它们的节奏与保留价值不同：指标每天一份、诊断稀疏。
    enum Kind: String, CaseIterable {
        case metrics
        case diagnostics
    }

    let directory: URL
    /// 每类留几份。系统每天最多交一次，20 份约等于三周。
    let retention: Int

    init(directory: URL, retention: Int = 20) {
        self.directory = directory
        self.retention = retention
    }

    /// 存一份，返回落盘路径。
    ///
    /// 文件名用毫秒时间戳：它天然可排序，而文件系统的修改时间在拷贝与恢复备份之后不可信。
    /// 13 位定长，所以字符串比较与数字比较同序。
    @discardableResult
    func save(_ data: Data, kind: Kind, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let url = directory.appendingPathComponent("\(kind.rawValue)-\(millis).json")
        try data.write(to: url, options: .atomic)
        prune(kind)
        return url
    }

    /// 某一类的文件，新的在前。
    func files(_ kind: Kind) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return all
            .filter { $0.lastPathComponent.hasPrefix("\(kind.rawValue)-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 超出保留份数就删最旧的。删失败不报错：留多一份比因为删不掉而整次写入失败好。
    private func prune(_ kind: Kind) {
        let all = files(kind)
        guard all.count > retention else { return }
        for url in all[retention...] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension TelemetryStore {

    /// 默认落点：`Application Support/Telemetry`。不进 Documents —— 那些是用户的东西，
    /// 而这些是我们自己排障用的。
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Telemetry", isDirectory: true)
    }
}

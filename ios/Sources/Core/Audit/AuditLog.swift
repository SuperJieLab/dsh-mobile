import Foundation

/// 写操作的结果。
///
/// 不叫 `Outcome`：那是界面层已经用着的类型名，而 `Core` 是下层、不得出现上层的名字
/// （有判据守着）。同名的两个类型在阅读时也会互相误导。
enum AuditResult: Equatable {
    case ok
    /// `code` 用协议词汇（`unknown-session` 之类），不是给用户看的句子。
    case refused(code: String)

    var word: String {
        switch self {
        case .ok: return "ok"
        case .refused: return "refused"
        }
    }

    var code: String? {
        switch self {
        case .ok: return nil
        case .refused(let code): return code
        }
    }
}

/// 一次写操作的审计记录。
///
/// 与日志的区别不是「重要程度」，是**记什么**：日志记过程（重试、状态迁移、中途失败），
/// 审计记结果（一次写 op 恰好一条，成功或被拒绝）。所以保留策略也不同 —— 日志轮转会丢掉
/// 前半，审计只按月切文件、从不丢弃。
struct AuditEntry: Equatable {
    let at: Date
    let op: String
    /// 被操作的对象：会话 / 工作空间 / 审批的 id。`-` 意为这次请求没带。
    let target: String
    let result: AuditResult
    /// 请求标记，与日志里的 `req=` 同值 —— 拿它去 grep 就是那一刻的现场。
    let requestId: String?
}

/// 审计的落盘与读取。
///
/// 按月切文件而不是按大小轮转：轮转要丢掉前半，而「谁删了那个工作空间」可能一个月后才问。
/// 切分只多一个文件，从不丢内容。增长量级按写 op 的次数算（一天几十条），不按时间算 ——
/// 一年几 MB，而日志是每天几百 KB。
final class AuditLog {

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// 追加一条。写不下去静默 —— 与日志同纪律：记不下来不该让一次写操作失败。
    /// 磁盘满时删工作空间失败，是比少一条审计更坏的交换。
    func record(_ entry: AuditEntry) {
        let line = AuditLine.format(entry) + "\n"
        let url = directory.appendingPathComponent(Self.fileName(for: entry.at))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // 这一次没记上，下一次写操作会再试。
        }
    }

    /// 最近 `limit` 条，**按时间倒序**。
    ///
    /// 文件名是 `audit-YYYY-MM.log`，字典序即时间序，所以从后往前读就是倒序 ——
    /// 不需要解析时间戳来排序。
    func recent(_ limit: Int) -> [AuditEntry] {
        guard limit > 0 else { return [] }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("audit-") && $0.hasSuffix(".log") }
            .sorted(by: >) ?? []

        var out: [AuditEntry] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard out.count < limit else { return out }
                if let entry = AuditLine.parse(String(line)) { out.append(entry) }
            }
        }
        return out
    }

    /// 时间戳属于哪个月的文件。`2026-11-04T…` → `audit-2026-11.log`。
    static func fileName(for at: Date) -> String {
        let stamp = LogTimestamp.string(from: at)
        return "audit-\(stamp.prefix(7)).log"
    }

    /// 默认落点：`Application Support/Audit/`。
    ///
    /// 与日志同处 `Application Support` 而不是 `Caches`：后者会被系统在磁盘紧张时删掉，
    /// 而那正是最想知道「上一次谁动过什么」的时候。
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Audit", isDirectory: true)
    }
}

/// 一行的拼法与解析。形状与网关那侧**逐字相同** —— 两端的记录能合到一起看，才谈得上
/// 「谁在什么时候做了什么」；两套格式就只是两份各自为政的文本。
enum AuditLine {

    static func format(_ entry: AuditEntry) -> String {
        var fields = ["op": entry.op, "target": entry.target, "result": entry.result.word]
        if let code = entry.result.code { fields["code"] = code }
        if let id = entry.requestId { fields["req"] = id }
        return "\(LogTimestamp.string(from: entry.at)) [audit]\(Log.formatFields(fields))"
    }

    /// 认不出的行返回 `nil` —— 半条记录读成一条比读不出来更坏，猜出来的目标会指向错的地方。
    static func parse(_ line: String) -> AuditEntry? {
        guard let marker = line.range(of: " [audit] ") else { return nil }
        let stamp = String(line[line.startIndex..<marker.lowerBound])
        guard let at = parser.date(from: stamp) else { return nil }

        var fields: [String: String] = [:]
        for part in line[marker.upperBound...].split(separator: " ") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            fields[String(part[part.startIndex..<equals])] = String(part[part.index(after: equals)...])
        }
        guard let op = fields["op"], let target = fields["target"] else { return nil }

        let result: AuditResult = fields["result"] == "ok"
            ? .ok
            : .refused(code: fields["code"] ?? "unknown")
        return AuditEntry(at: at, op: op, target: target, result: result, requestId: fields["req"])
    }

    private static let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - 哪些请求是写操作

/// 写请求能说出自己作用在什么上 —— 审计要的那一格。
///
/// 不做成 `GatewayRequest` 的必需成员：读请求没有作用对象，让它们都实现一个返回 `-` 的属性，
/// 等于把「哪些是写」从类型上抹掉。**实现了本协议 = 这是一次写操作**，所以两端不需要各维护
/// 一份 op 清单 —— 网关那份是唯一真源，这边由类型表达。
protocol AuditableRequest {
    var auditTarget: String { get }
}

extension SessionPromptRequest: AuditableRequest {
    var auditTarget: String { sessionId }
}

extension ApprovalAnswerRequest: AuditableRequest {
    var auditTarget: String { eventId }
}

extension CommandExecuteRequest: AuditableRequest {
    var auditTarget: String { sessionId }
}

extension PermissionSelectRequest: AuditableRequest {
    var auditTarget: String { sessionId }
}

extension ModelSelectRequest: AuditableRequest {
    var auditTarget: String { sessionId }
}

extension SessionCreateRequest: AuditableRequest {
    /// 不带 `workspaceId` 意为「交给宿主当前目录」：不是缺失，是一个明确的「未指定」。
    var auditTarget: String { workspaceId ?? "-" }
}

extension WorkspaceCreateRequest: AuditableRequest {
    var auditTarget: String { name }
}

extension WorkspaceDeleteRequest: AuditableRequest {
    var auditTarget: String { workspaceId }
}

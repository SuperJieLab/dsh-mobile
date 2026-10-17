import XCTest

/// 术语回潮检查（R13 期2）—— 扫 `ios/Sources` 与 `ios/tests` 的注释，命中仓库根 `terms.txt`
/// 的反模式即失败。
///
/// 词表与网关侧是同一份（`terms.txt` 在仓库根）⇒ 结构上不可能漂移。表里还有一组
/// 「自查样本」（`expect-hit` / `expect-pass`）：加载后先跑一遍，**规则被改坏时这里先红**，
/// 不必等仓库真的回潮。
///
/// 只报不改：「承载」按句意分两种写法（组网 / 传输），没有唯一解，自动替换正是期1 那 60 处误伤
/// 的来源。
///
/// 豁免：`terms-ok:<理由>` 行内豁免，或 `terms-ok:start` / `terms-ok:end` 块豁免。
/// 块**必须配对** —— 未闭合会让余下全文静默失明，所以每个文件扫完都会单独报一次并指出
/// `:start` 所在行。豁免了什么会被打印出来：豁免应当可见，否则「散文里写一句 terms-ok:」
/// 就能静默关掉一行而无人知道。
///
/// 本文件的路径推算（`#filePath` 上溯三级）在 T1 的探针里验过：测试进程能读宿主机文件。
final class TermsTests: XCTestCase {
    /// 仓库根：`<repo>/ios/tests/TermsTests.swift` 向上三级。
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ios/tests/
            .deletingLastPathComponent()   // ios/
            .deletingLastPathComponent()   // <repo>
    }

    private struct Rule {
        let word: String
        let regex: NSRegularExpression
        let advice: String
        let reason: String
    }

    private struct Sample {
        let expectHit: Bool
        let text: String
        let line: Int
    }

    private enum Marker {
        case start
        case end
        case line
    }

    /// `terms-ok:start` / `terms-ok:end` / `terms-ok:<理由>`；没带冒号或理由为空都不算标记。
    /// 冒号后允许空白 —— 中文注释习惯写成「terms-ok: 理由」，不放宽（含全角空格）会静默失效。
    private func markerOf(_ line: String) -> Marker? {
        guard let range = line.range(of: "terms-ok:") else { return nil }
        let rest = line[range.upperBound...].drop(while: { $0.isWhitespace })
        let token = rest.prefix { !$0.isWhitespace }
        if token == "start" { return .start }
        if token == "end" { return .end }
        return token.isEmpty ? nil : .line
    }

    private func loadTable() throws -> (rules: [Rule], samples: [Sample]) {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("terms.txt"), encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "terms.txt 是空的")
        var rules: [Rule] = []
        var samples: [Sample] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let location = "terms.txt:\(index + 1)"
            if line.hasPrefix("expect-hit;") || line.hasPrefix("expect-pass;") {
                let expectHit = line.hasPrefix("expect-hit;")
                let prefix = expectHit ? "expect-hit;" : "expect-pass;"
                let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else {
                    XCTFail("\(location) 的自查样本是空的")
                    continue
                }
                samples.append(Sample(expectHit: expectHit, text: text, line: index + 1))
                continue
            }
            let parts = line.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else {
                XCTFail("\(location) 格式不对（应为 词;正则;建议[;理由]）: \(line)")
                continue
            }
            guard !parts[1].isEmpty else {
                XCTFail("\(location) 有空正则（\(parts[0])）—— 它会命中每一行: \(line)")
                continue
            }
            do {
                rules.append(Rule(word: parts[0],
                                  regex: try NSRegularExpression(pattern: parts[1]),
                                  advice: parts[2],
                                  reason: parts.count > 3 ? parts[3] : ""))
            } catch {
                XCTFail("\(location) 的正则写错了（\(parts[0])）: \(parts[1]) —— \(error)")
            }
        }
        return (rules, samples)
    }

    private func matches(_ rule: Rule, in text: String) -> Bool {
        rule.regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private func swiftFiles(under dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: dir,
                                                              includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" { out.append(url) }
        return out.filter { $0.lastPathComponent != "TermsTests.swift" }
    }

    /// 命中详情写盘。
    ///
    /// 为什么不能只靠断言消息：XCTest 的 message 进 xcresult，命令行只显示「failed」；
    /// 而 `xcodebuild -quiet` 会把测试进程的 stdout 也压掉（R13 期2 实测）。判据要求
    /// 「输出指出文件与行」，所以留一份可读的落盘报告 —— 文件名以 `.log` 结尾，已在
    /// `.gitignore` 里。
    private var reportURL: URL { repoRoot.appendingPathComponent("ios/.terms-check.log") }

    private func writeReport(_ lines: [String]) {
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(to: reportURL, atomically: true, encoding: .utf8)
        print(body)
    }

    private func clearReport() {
        try? FileManager.default.removeItem(at: reportURL)
    }

    private func scan(files: [URL], rules: [Rule]) throws -> (hits: [String], exempted: [String]) {
        var hits: [String] = []
        var exempted: [String] = []
        for file in files {
            let rel = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            let contents = try String(contentsOf: file, encoding: .utf8)
            var blockOpenAt = 0
            // `whereSeparator: \.isNewline` 同时处理 LF 与 CRLF：`\r\n` 在 Swift 里是单个
            // Character，按 "\n" 切会把整个 CRLF 文件当成一行。
            for (index, raw) in contents.split(whereSeparator: \.isNewline).enumerated() {
                let line = String(raw)
                switch markerOf(line) {
                case .end:
                    blockOpenAt = 0
                    continue
                case .start:
                    blockOpenAt = index + 1
                    continue
                case .line:
                    exempted.append("\(rel):\(index + 1)")
                    continue
                case nil:
                    break
                }
                if blockOpenAt > 0 { continue }
                for rule in rules where matches(rule, in: line) {
                    let why = rule.reason.isEmpty ? "" : "（\(rule.reason)）"
                    hits.append("\(rel):\(index + 1)  「\(rule.word)」→ \(rule.advice)\(why)")
                }
            }
            if blockOpenAt > 0 {
                hits.append("\(rel):\(blockOpenAt)  terms-ok:start 没有配对的 :end —— 从这里到文件末尾被跳过")
            }
        }
        return (hits, exempted)
    }

    func testNoRetiredTerms() throws {
        let (rules, samples) = try loadTable()
        XCTAssertFalse(rules.isEmpty, "terms.txt 里一条规则都没解析出来")
        XCTAssertFalse(samples.isEmpty, "terms.txt 里一条自查样本都没有 —— 规则被改坏时会静默全绿")

        // 先让规则自己过一遍样本：`expect-hit` 必须命中，`expect-pass` 必须不命中。
        var wrong: [String] = []
        for sample in samples {
            let matched = rules.filter { matches($0, in: sample.text) }
            let ok = sample.expectHit ? !matched.isEmpty : matched.isEmpty
            if !ok {
                let detail = matched.isEmpty
                    ? "一条规则都没命中"
                    : "被「\(matched.map(\.word).joined(separator: "、"))」命中"
                wrong.append("terms.txt:\(sample.line)  expect-\(sample.expectHit ? "hit" : "pass") 被违反"
                             + " —— \(detail)：\(sample.text)")
            }
        }
        // 样本都不对，后面的扫描结论没有意义 —— 写完报告就收工，别让 clearReport 把它删了。
        if !wrong.isEmpty {
            writeReport(["自查样本与规则不一致（改规则时把样本也一起看）："] + wrong.map { "  " + $0 })
            XCTFail("自查样本与规则不一致 \(wrong.count) 处 —— 详情见 ios/.terms-check.log")
            return
        }

        let files = swiftFiles(under: repoRoot.appendingPathComponent("ios/Sources"))
            + swiftFiles(under: repoRoot.appendingPathComponent("ios/tests"))
        // 扫到 0 个文件时 hits 也是空 —— 那会静默变绿，所以先断言扫到了东西。
        XCTAssertGreaterThan(files.count, 10, "只扫到 \(files.count) 个 Swift 文件 —— 路径推算错了？")

        let (hits, exempted) = try scan(files: files, rules: rules)
        if !exempted.isEmpty { print("ℹ️ 行内豁免 \(exempted.count) 处：\(exempted.joined(separator: "、"))") }
        if hits.isEmpty {
            clearReport()
        } else {
            writeReport(["术语回潮检查命中 \(hits.count) 处（改成建议列里的说法）："] + hits.map { "  " + $0 })
        }
        XCTAssertTrue(hits.isEmpty,
                      "术语回潮检查命中 \(hits.count) 处 —— 详情见 ios/.terms-check.log")
    }
}

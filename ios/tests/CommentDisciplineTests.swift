/**
 * 源码注释的常驻判据 —— 注释要能自己说清，不靠仓库外的东西。
 *
 * 三组规则（读 `ios/comment-rules.txt`）+ 两条独立判据：
 * 1. 注释不指向开发工作区（路径、期号、决定号、节号、条款号、判据号、里程碑号）；
 * 2. 注释不按行号引上游 —— 上游是 alpha，行号必漂，我们依赖的是形状；
 * 3. 注释不写变更史与一次性现场 —— 前者描述已不存在的对象，后者是举证不是判据；
 * 4. 同一条判据只在一处展开；注释行不超过 100 显示列。
 *
 * 两条形状上的选择，代价都写在这里：
 * - **逐行扫，不剥字符串。** 剥字符串要写一个认模板插值的词法器；写错时是漏报
 *   （网关侧那次的插值被一并删掉，让一段判据长期假绿）。按行粗扫写错只会多报，
 *   多报会有人来看一眼。代价：字符串里合法出现被禁字样会假红，用行内豁免放行。
 * - **模式与样本读 `comment-rules.txt`，不内联。** 模式词表本身含中文，内联会被
 *   这条判据自己扫到。代价：多一份要维护的文件。
 *
 * 两向都要红：规则改坏（正则退化成永不命中）时样本先红；仓库回潮时 offenders 非空。
 * 只守住前者会漏掉真实的回潮，只守住后者会在扫描器瞎掉时全绿。
 *
 * 跑法：`xcodebuild test -only-testing:DshMobileTests/CommentDisciplineTests`。
 */
import Foundation
import XCTest

final class CommentDisciplineTests: XCTestCase {

    // MARK: - 读源码与规则

    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ios/tests/
            .deletingLastPathComponent() // ios/
    }

    private func swiftFiles() -> [URL] {
        var result: [URL] = []
        for sub in ["Sources", "tests"] {
            let root = iosRoot.appendingPathComponent(sub)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// 一条规则：`id` + 正则 + 说明，外加自带的样本。
    private struct Rule {
        let id: String
        let pattern: NSRegularExpression
        let note: String
        var hits: [String] = []
        var passes: [String] = []
    }

    private struct RuleFile {
        let rules: [Rule]
        /// 组四：一条判据的点名短语，按「判据名」归组 —— 整组只允许出现一次。
        let singleExpansions: [(name: String, phrase: String)]
        let missingSamples: [String]
    }

    /// 解析 `comment-rules.txt`。格式见该文件头注释。
    private func readRules() throws -> RuleFile {
        let path = iosRoot.appendingPathComponent("comment-rules.txt")
        let text = try String(contentsOf: path, encoding: .utf8)
        var rules: [Rule] = []
        var byId: [String: Int] = [:]
        var single: [(name: String, phrase: String)] = []
        var missing: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.components(separatedBy: ";")
            guard fields.count >= 3 else { continue }
            let kind = fields[0]
            let id = fields[1]
            let body = fields[2]
            switch kind {
            case "rule":
                guard fields.count >= 4 else {
                    XCTFail("规则 \(id) 缺说明（第四段）")
                    continue
                }
                guard let regex = try? NSRegularExpression(pattern: body) else {
                    XCTFail("规则 \(id) 的正则编不过：\(body)")
                    continue
                }
                byId[id] = rules.count
                rules.append(Rule(id: id, pattern: regex, note: fields[3]))
            case "single":
                single.append((name: id, phrase: body))
            case "expect-hit":
                if let index = byId[id] { rules[index].hits.append(body) } else { missing.append(id) }
            case "expect-pass":
                if let index = byId[id] { rules[index].passes.append(body) } else { missing.append(id) }
            default:
                XCTFail("规则文件里有不认识的段类型：\(kind)")
            }
        }
        return RuleFile(rules: rules, singleExpansions: single, missingSamples: missing)
    }

    /// 逐行返回，**不区分注释与代码**：按行扫、不剥字符串，见文件头。
    ///
    /// 早先只认「含 `//`、`/*`、行首 `*`」的行，结果块注释里不带星号的续行整段漏扫 ——
    /// 那正是漏报。现在每行都过，代价只是代码行也可能假红。
    private func scannedLines(in file: URL) -> [(Int, String)] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset + 1, String($0.element)) }
    }

    /// 豁免：行内的 `comment-ok` 加一个冒号与理由。理由为空即视为无效豁免
    /// （不带理由就是关掉纪律）。
    private func exemptionReason(in line: String) -> String? {
        guard let range = line.range(of: "comment-ok:") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private struct Offender {
        let file: String
        let line: Int
        let excerpt: String
    }

    private func offenders(of rule: Rule, in files: [URL]) -> [Offender] {
        var result: [Offender] = []
        for file in files {
            for (number, line) in scannedLines(in: file) {
                if exemptionReason(in: line) != nil { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard rule.pattern.firstMatch(in: line, range: range) != nil else { continue }
                let relative = file.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
                result.append(Offender(file: relative, line: number,
                                       excerpt: line.trimmingCharacters(in: .whitespaces).prefix(100)
                                           .description))
            }
        }
        return result
    }

    private func report(_ offenders: [Offender], rule: Rule) {
        guard !offenders.isEmpty else { return }
        let lines = offenders.map { "\($0.file):\($0.line)  \($0.excerpt)" }.joined(separator: "\n")
        XCTFail("""
            \(offenders.count) 处注释违反「\(rule.note)」（规则 \(rule.id)）：
            \(lines)
            """)
    }

    // MARK: - 规则文件自身的活性

    /// 零命中型判据的安全网：样本必须被它守的那条规则抓到。
    /// 正则退化成永不命中、或样本被删，这里先红 —— 否则全仓会静默变绿。
    func testEveryRuleCatchesItsOwnSample() throws {
        let file = try readRules()
        XCTAssertTrue(file.missingSamples.isEmpty,
                      "这些样本没有对应的规则：\(file.missingSamples.joined(separator: ", "))")
        XCTAssertFalse(file.rules.isEmpty, "一条规则都没读到：\(iosRoot.path)/comment-rules.txt")
        for rule in file.rules {
            XCTAssertFalse(rule.hits.isEmpty, "规则 \(rule.id) 没有 expect-hit 样本，无法自证活着")
            for sample in rule.hits {
                let range = NSRange(sample.startIndex..., in: sample)
                XCTAssertNotNil(rule.pattern.firstMatch(in: sample, range: range),
                                "规则 \(rule.id) 抓不到自己的样本：\(sample)")
            }
            for sample in rule.passes {
                let range = NSRange(sample.startIndex..., in: sample)
                XCTAssertNil(rule.pattern.firstMatch(in: sample, range: range),
                             "规则 \(rule.id) 误伤了 expect-pass 样本：\(sample)")
            }
        }
    }

    /// 扫描面自己也得活着：路径写错、目录改名时，枚举会返回空而四条判据一起变绿。
    func testScanSurfaceIsNotEmpty() {
        let files = swiftFiles()
        XCTAssertGreaterThanOrEqual(files.count, 50, "扫到的 .swift 太少，扫描面可能瞎了：\(files.count)")
        let lineCount = files.reduce(0) { $0 + scannedLines(in: $1).count }
        XCTAssertGreaterThanOrEqual(lineCount, 5000, "扫到的行太少：\(lineCount)")
    }

    // MARK: - 三组要求

    private func assertNoOffenders(ruleIds: [String]) throws {
        let file = try readRules()
        let files = swiftFiles()
        for id in ruleIds {
            guard let rule = file.rules.first(where: { $0.id == id }) else {
                XCTFail("规则文件里没有 \(id)")
                continue
            }
            report(offenders(of: rule, in: files), rule: rule)
        }
    }

    /// 组一：指向开发工作区的锚点。那些文档不随仓库发布，读者点不开。
    func testCommentsCarryNoWorkspaceAnchors() throws {
        try assertNoOffenders(ruleIds: [
            "workspace-path", "workspace-phase", "workspace-decision", "workspace-section",
            "workspace-clause", "workspace-chain", "workspace-amendment", "workspace-criterion",
            "workspace-milestone", "workspace-register", "workspace-phase-word",
        ])
    }

    /// 组二：按行号引上游。上游是 alpha，连 patch 级预发布内都会改形状。
    func testCommentsDoNotCiteUpstreamLines() throws {
        try assertNoOffenders(ruleIds: ["upstream-line"])
    }

    /// 组三：变更史与一次性现场。前者描述已不存在的对象，后者是举证不是判据。
    func testCommentsDescribeThePresentOnly() throws {
        try assertNoOffenders(ruleIds: ["history", "scene-date", "scene-evidence"])
    }

    // MARK: - 同一条判据只展开一处

    /// 四组判据各自的展开处 —— 每处只允许一次。
    ///
    /// 短语表住 `comment-rules.txt`：写在判据文件里的话，判据会数到自己那一行，
    /// 于是这条判据永远红（这正是「模式不能内联」的同一个理由）。
    func testEachJudgementIsExpandedOnce() throws {
        let file = try readRules()
        XCTAssertFalse(file.singleExpansions.isEmpty, "组四的短语表是空的")
        let files = swiftFiles()
        var counts: [String: [String]] = [:]
        for entry in file.singleExpansions {
            for swiftFile in files {
                for (number, line) in scannedLines(in: swiftFile) {
                    if exemptionReason(in: line) != nil { continue }
                    guard line.contains(entry.phrase) else { continue }
                    let relative = swiftFile.path
                        .replacingOccurrences(of: iosRoot.path + "/", with: "")
                    counts[entry.name, default: []].append("\(relative):\(number)  \(entry.phrase)")
                }
            }
        }
        for (name, found) in counts {
            XCTAssertLessThanOrEqual(found.count, 1, """
                「\(name)」这条判据展开了 \(found.count) 处，只该有一处：
                \(found.joined(separator: "\n"))
                """)
        }
    }

    // MARK: - 格式

    /// 行宽不超过 100 显示列（中日韩字符按 2 列）。
    ///
    /// 只查**注释行**：代码行的长度由编译器的换行习惯决定，管它会把 `guard let … else {`
    /// 这类本来就长的一行算成违规。块注释的续行要带 `*` 才算得进来 —— 不带星号的写法
    /// 在行宽这一条上是盲区，宁可漏。
    func testCommentLinesFitTheWidth() {
        var offenders: [String] = []
        for file in swiftFiles() {
            for (number, line) in scannedLines(in: file) {
                if exemptionReason(in: line) != nil { continue }
                let stripped = line.trimmingCharacters(in: .whitespaces)
                let isComment = stripped.hasPrefix("//") || stripped.hasPrefix("/*")
                    || stripped.hasPrefix("*")
                guard isComment else { continue }
                let width = line.reduce(0) { $0 + Self.displayWidth(of: $1) }
                guard width > 100 else { continue }
                let relative = file.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
                offenders.append("\(relative):\(number)  \(width) 列")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "这些注释超过了 100 显示列：\n\(offenders.joined(separator: "\n"))")
    }

    private static func displayWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    // MARK: - 豁免

    /// 豁免要看得见，也要说得清：用到的逐条打印，理由为空直接失败。
    func testExemptionsAreVisibleAndReasoned() {
        var used: [String] = []
        for file in swiftFiles() {
            for (number, line) in scannedLines(in: file) {
                guard let reason = exemptionReason(in: line) else { continue }
                let relative = file.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
                XCTAssertFalse(reason.isEmpty, "\(relative):\(number) 的豁免没写理由 —— 没有理由就是关掉纪律")
                used.append("\(relative):\(number)  \(reason)")
            }
        }
        if !used.isEmpty {
            print("豁免清单（\(used.count) 处）：\n" + used.joined(separator: "\n"))
        }
    }
}

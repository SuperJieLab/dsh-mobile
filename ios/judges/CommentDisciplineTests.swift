/**
 * 注释里剩下这几条判据 —— 单行正则表达不了的那部分。
 *
 * 单行能判的注释纪律（指向开发工作区的锚点、按行号引上游、变更史、元信息）住在
 * `ios/.swiftlint.yml`：那些规则要的是保存即报，放进测试永远慢一个量级。
 *
 * 留在这里的三类，都是要看相邻行或要数文件的：
 * 1. 同一条判断的展开处全仓只许一处 —— 得数文件；
 * 2. 文件头注释的首段不超过六行 —— 得看相邻行；
 * 3. 注释行不超过一百显示列 —— 得按中日韩字宽折算，一个字符算两列。
 *
 * 三条都建立在「扫到多少文件」这个前提上，所以另有一条判据只看扫描面本身：路径推算瞎了
 * 的时候，上面三条会一起变绿。
 */
import Foundation
import XCTest

final class CommentDisciplineTests: XCTestCase {

    // MARK: - 读源码与短语表

    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ios/tests/
            .deletingLastPathComponent() // ios/
    }

    private func swiftFiles() -> [URL] {
        var result: [URL] = []
        for sub in ["Sources", "tests", "judges"] {
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

    private struct Phrase {
        let name: String
        let text: String
    }

    /// 短语表住在单独的文件里 —— 写进本文件的话，判据会数到自己那一行，于是永远红。
    private func readPhrases() throws -> [Phrase] {
        let path = iosRoot.appendingPathComponent("single-expansion-phrases.txt")
        let text = try String(contentsOf: path, encoding: .utf8)
        var phrases: [Phrase] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.components(separatedBy: ";")
            guard fields.count >= 3, fields[0] == "single" else { continue }
            phrases.append(Phrase(name: fields[1], text: fields[2]))
        }
        return phrases
    }

    /// 逐行返回，不区分注释与代码：这几条判据都要看没有注释标记的行（首段的分隔靠空注释行）。
    private func scannedLines(in file: URL) -> [(Int, String)] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset + 1, String($0.element)) }
    }

    // MARK: - 扫描面

    /// 扫描面自己也得活着：路径写错、目录改名时，枚举会返回空，其余判据一起变绿。
    func testScanSurfaceIsNotEmpty() {
        let files = swiftFiles()
        XCTAssertGreaterThanOrEqual(files.count, 50, "扫到的 .swift 太少，扫描面可能瞎了：\(files.count)")
        let lineCount = files.reduce(0) { $0 + scannedLines(in: $1).count }
        XCTAssertGreaterThanOrEqual(lineCount, 5000, "扫到的行太少：\(lineCount)")
    }

    // MARK: - 头注释的分层

    /// 文件头注释的首段不超过六行。
    ///
    /// 首段回答「这个文件管什么」，读者看它决定要不要往下读；推导与陷阱放后面的段。
    func testHeadCommentsLeadWithOneShortParagraph() {
        var offenders: [String] = []
        for file in swiftFiles() {
            guard let first = headParagraph(of: file) else { continue }
            guard first.count > 6 else { continue }
            let relative = file.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
            offenders.append("\(relative)  首段 \(first.count) 行")
        }
        XCTAssertTrue(offenders.isEmpty, """
            这些文件头注释的首段太长，读者看不出它管什么：
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// 文件头注释的首段：第一行注释起到第一个空注释行为止的正文。
    private func headParagraph(of file: URL) -> [String]? {
        let lines = scannedLines(in: file).map { $0.1 }
        var started = false
        var paragraph: [String] = []
        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            let isComment = stripped.hasPrefix("//") || stripped.hasPrefix("/*")
                || stripped.hasPrefix("*")
            if !started {
                guard isComment else { continue }
                started = true
            }
            guard isComment else { break }
            let body = stripped
                .replacingOccurrences(of: "/**", with: "")
                .replacingOccurrences(of: "///", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "*/ \t"))
            if body.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(body)
        }
        return paragraph
    }

    // MARK: - 同一条判断只展开一处

    /// 短语表里每组的短语，全仓只许出现一次。
    ///
    /// 数的是「出现过几行」，不是「出现过几次」：同一行里写两遍属于同一处展开。
    func testEachJudgementIsExpandedOnce() throws {
        let phrases = try readPhrases()
        XCTAssertFalse(phrases.isEmpty, "短语表是空的")
        let files = swiftFiles()
        var counts: [String: [String]] = [:]
        for phrase in phrases {
            for swiftFile in files {
                for (number, line) in scannedLines(in: swiftFile) {
                    guard line.contains(phrase.text) else { continue }
                    let relative = swiftFile.path
                        .replacingOccurrences(of: iosRoot.path + "/", with: "")
                    counts[phrase.name, default: []].append("\(relative):\(number)  \(phrase.text)")
                }
            }
        }
        for (name, found) in counts {
            XCTAssertLessThanOrEqual(found.count, 1, """
                「\(name)」这条判断展开了 \(found.count) 处，只该有一处：
                \(found.joined(separator: "\n"))
                """)
        }
    }

    // MARK: - 格式

    /// 注释行不超过一百显示列（中日韩字符按两列）。
    ///
    /// 只查注释行：代码行的长度由编译器的换行习惯决定。块注释的续行要带 `*` 才算得进来 ——
    /// 不带星号的写法在这条上是盲区，宁可漏。
    func testCommentLinesFitTheWidth() {
        var offenders: [String] = []
        for file in swiftFiles() {
            for (number, line) in scannedLines(in: file) {
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
        XCTAssertTrue(offenders.isEmpty, "这些注释超过了上限：\n\(offenders.joined(separator: "\n"))")
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
}

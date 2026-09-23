/**
 * Markdown 解析器 —— 源文 → `[Block]`。
 *
 * **纯状态机：不 import SwiftUI / UIKit**，故能被 `swiftc` 编成命令行程序跑断言
 * （`ios/tests/run-markdown.sh`）。渲染层（`MarkdownText`）只认 `[Block]`，不认源文。
 * 引任何 Swift 包都会断掉编译验证链（`swiftc -typecheck` 直编源码，不经 xcodeproj、
 * 不解析 SPM），所以连解析也自写。**分层是为留门** —— 将来换成熟库只替换这一层，把库的
 * AST 映射成同一个 `[Block]`，渲染与流式策略不动。见
 * `docs/dev/plans/M6-presentation-layer.md` §3.3 决定 15。
 *
 * ## 子集（六种，其余登记不做）
 *
 * 围栏代码块（```）· 标题（`#` 1–6 级）· 无序列表（`-` `*` `+`）· 有序列表（`1.` / `1)`）·
 * 引用（`>`）· 分隔线（`---` `***` `___`）。**不做**（显示为纯文本，见 §1.3）：表格 /
 * 嵌套列表 / 任务列表 / 脚注 / 数学公式 / 原始 HTML / setext 标题（`标题` 下行 `---` 会读成
 * 段落 + 分隔线）/ 引用式链接定义（`[ref]: url`，行内片段逐个单独解析，收不到别处定义）。
 *
 * ## 流式：尾部冻结
 *
 * 照上游语义（`ui-primitives/src/markdown/incremental.ts:1-29`）：**除尾部之外全部冻结，每
 * chunk 只重解析尾部** —— 上游按两块、我们按一块（它要处理引用式定义与脚注的双向依赖，我们
 * 的子集里新内容只影响最后一块）。「冻结」是**结果上的**：`parse(_:extending:)` 收下上一次
 * 的结果，新源文是旧源文前缀时搬运冻结段、只从冻结边界之后重扫（`reparsedFrom` 记下重扫
 * 起点，供断言）；源文以空行结尾时最后一块也已封口，可一起冻结。未闭合围栏**当场按代码块
 * 渲染**，其身份（源偏移）在生长过程中稳定、界面不闪（不是先按段落、闭合后再跳变更）。
 * 判据 M4。
 */

import Foundation

// MARK: - 块

/// 一个块级元素。
///
/// `offset` 是**起始行在源文里的字符偏移**，也是它的身份 —— 渲染层用它做 key，冻结块的
/// offset 不变，SwiftUI 便不重挂载、不重排（判据 M3）。
struct Block: Equatable {

    enum Kind: Equatable {
        /// `#` 到 `######`，`level` ∈ 1...6。
        case heading(level: Int)
        /// 普通段落（连续非空行合成一块）。
        case paragraph
        /// 围栏代码块。`language` 是围栏后那串标记（`nil` = 没写）。
        case code(language: String?)
        /// **一级**列表项。`marker` 原样保留；圆点与序号由渲染层画 —— 系统的行内解析不给。
        case listItem(ordered: Bool, marker: String)
        /// 引用（连续的 `>` 行合成一块，`text` 里的行以换行分隔）。
        case quote
        /// 分隔线。
        case divider
    }

    let kind: Kind
    /// 块的正文。代码块是代码原文（不含围栏），列表项是项文本（不含标记）。
    let text: String
    /// 起始行偏移 —— 也是这一块的身份。
    let offset: Int
}

extension Block: Identifiable {
    var id: Int { offset }
}

// MARK: - 解析结果

/// 一次解析的结果。除块本身外，另带两件给流式用的记账。
struct MarkdownParse: Equatable {
    /// 这次解析对应的源文。`extending` 靠它判断「新源文是不是在旧源文后面接着长」。
    let source: String
    let blocks: [Block]
    /// 前 `frozenCount` 个块已经封口，下次喂新内容时原样搬运、不重解析。
    let frozenCount: Int
    /// 这次解析**从哪个字符偏移开始扫**。全量解析恒为 0；增量解析时它等于冻结边界
    /// 之后第一块的起点 —— 断言「只重解析尾部」的直接证据（判据 M3）。
    let reparsedFrom: Int
}

// MARK: - 解析器

enum MarkdownParser {

    /// 围栏标记。只认三个反引号（`~~~` 不在子集里）。
    private static let fence = "```"

    /// 全量解析。
    static func parse(_ source: String) -> MarkdownParse {
        let blocks = scan(lines(of: source), from: 0)
        return MarkdownParse(source: source,
                             blocks: blocks,
                             frozenCount: frozenCount(of: source, blocks: blocks),
                             reparsedFrom: 0)
    }

    /// 增量解析：`previous` 是同一份文本更早的解析结果。
    ///
    /// 新源文是旧源文的前缀延长时，冻结段原样搬运、只重扫尾部；否则老实全量重解 ——
    /// 宁可多算，不可算错。
    static func parse(_ source: String, extending previous: MarkdownParse) -> MarkdownParse {
        guard source.hasPrefix(previous.source) else { return parse(source) }

        // 冻结边界之后第一块的起点；全部冻结（源文以空行结尾）时从旧源文末尾接着扫，位置仍是行首。
        let resume = previous.blocks.count > previous.frozenCount
            ? previous.blocks[previous.frozenCount].offset
            : previous.source.count
        guard resume <= source.count else { return parse(source) }

        let frozen = Array(previous.blocks.prefix(previous.frozenCount))
        let all = lines(of: source)
        let start = all.firstIndex { $0.offset >= resume } ?? all.count
        let blocks = frozen + scan(all, from: start)
        return MarkdownParse(source: source,
                             blocks: blocks,
                             frozenCount: frozenCount(of: source, blocks: blocks),
                             reparsedFrom: resume)
    }

    /// 行内：一段行内 markdown → 富文本。
    ///
    /// 块级自己做（系统在 `Text` 上不做块级排版），行内**交给系统**（粗体 / 斜体 / 行内码 /
    /// 链接）。它是纯函数（`AttributedString` 来自 Foundation），故进 CLI 断言（判据 M2）。
    /// `inlineOnlyPreservingWhitespace` 是关键：**只解行内**、空白原样保留，于是「一段里既有
    /// 文字又有标记」时不会被系统重新断行。
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - 冻结记账

    /// 尾部之外的块已经封口。以空行结尾时最后一块也封了。
    private static func frozenCount(of source: String, blocks: [Block]) -> Int {
        guard !blocks.isEmpty else { return 0 }
        let sealed = source.hasSuffix("\n\n")
        return sealed ? blocks.count : blocks.count - 1
    }

    // MARK: - 行

    /// 源文的一行：内容 + 它在源文里的字符偏移。
    private struct SourceLine {
        let text: String
        let offset: Int
    }

    /// 按 `\n` 切行，逐行记住起始偏移。`omittingEmptySubsequences: false` 有意 ——
    /// 空行是分段的依据。
    private static func lines(of source: String) -> [SourceLine] {
        var result: [SourceLine] = []
        var offset = 0
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            result.append(SourceLine(text: text, offset: offset))
            offset += text.count + 1
        }
        return result
    }

    // MARK: - 扫描

    /// 从第 `start` 行开始扫描出块。增量解析时 `start` 就是冻结边界之后那一行 ——
    /// 这就是「只重解析尾部」。
    private static func scan(_ lines: [SourceLine], from start: Int) -> [Block] {
        var blocks: [Block] = []
        var index = start

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            // 空行只用来分段，自己不成块
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // 围栏代码块：收到闭合围栏或源文结束
            if trimmed.hasPrefix(fence) {
                var content: [String] = []
                var cursor = index + 1
                while cursor < lines.count, !isFenceCloser(lines[cursor].text) {
                    content.append(lines[cursor].text)
                    cursor += 1
                }
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(kind: .code(language: language.isEmpty ? nil : language),
                                    text: content.joined(separator: "\n"),
                                    offset: line.offset))
                // 没找到闭合就是「还在长」：这一块吃掉剩下的全部
                index = cursor < lines.count ? cursor + 1 : lines.count
                continue
            }

            // 标题
            if let level = headingLevel(of: trimmed) {
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(kind: .heading(level: level), text: text, offset: line.offset))
                index += 1
                continue
            }

            // 分隔线。**要排在列表前面**：`- - -` 也是分隔线，而按列表记号看它是三项
            if isDivider(trimmed) {
                blocks.append(Block(kind: .divider, text: "", offset: line.offset))
                index += 1
                continue
            }

            // 引用：连续的 `>` 行合成一块
            if trimmed.hasPrefix(">") {
                var parts: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let quoted = lines[cursor].text.trimmingCharacters(in: .whitespaces)
                    guard quoted.hasPrefix(">") else { break }
                    parts.append(quoteBody(quoted))
                    cursor += 1
                }
                blocks.append(Block(kind: .quote, text: parts.joined(separator: "\n"), offset: line.offset))
                index = cursor
                continue
            }

            // 列表项：一项一块，记号原样留着给渲染层画
            if let marker = listMarker(of: trimmed) {
                var parts = [String(trimmed.dropFirst(marker.length)).trimmingCharacters(in: .whitespaces)]
                var cursor = index + 1
                while cursor < lines.count {
                    let next = lines[cursor].text.trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || startsBlock(next) { break }
                    parts.append(next)      // 续行并入同一项
                    cursor += 1
                }
                blocks.append(Block(kind: .listItem(ordered: marker.ordered, marker: marker.token),
                                    text: parts.joined(separator: " "),
                                    offset: line.offset))
                index = cursor
                continue
            }

            // 段落：连续行到空行或下一个块的起始
            var parts: [String] = []
            var cursor = index
            while cursor < lines.count {
                let next = lines[cursor].text.trimmingCharacters(in: .whitespaces)
                if next.isEmpty { break }
                if cursor > index, startsBlock(next) { break }
                parts.append(next)
                cursor += 1
            }
            blocks.append(Block(kind: .paragraph, text: parts.joined(separator: "\n"), offset: line.offset))
            index = cursor
        }

        return blocks
    }

    /// 这一行是不是另一个块的起始 —— 段落与列表项的收集都靠它收口。
    private static func startsBlock(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix(fence) { return true }
        if headingLevel(of: trimmed) != nil { return true }
        if isDivider(trimmed) { return true }
        if trimmed.hasPrefix(">") { return true }
        return listMarker(of: trimmed) != nil
    }

    /// 闭合围栏：三个反引号之后只剩空白。
    private static func isFenceCloser(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(fence) else { return false }
        return trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `#` 到 `######`，且井号之后要么结束、要么是空格（`#话题` 不是标题）。
    private static func headingLevel(of trimmed: String) -> Int? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard level >= 1, level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return level
    }

    /// 分隔线：全是同一个记号（`-` / `*` / `_`）且至少三个，记号之间可以有空格。
    private static func isDivider(_ trimmed: String) -> Bool {
        let stripped = trimmed.filter { !$0.isWhitespace }
        guard stripped.count >= 3, let mark = stripped.first, "-*_".contains(mark) else { return false }
        return stripped.allSatisfy { $0 == mark }
    }

    /// 列表记号：`-` / `*` / `+`，或数字后跟 `.` / `)`。序号原样保留，不从 1 重编。
    private static func listMarker(of trimmed: String) -> (ordered: Bool, token: String, length: Int)? {
        for token in ["-", "*", "+"] where trimmed.hasPrefix(token + " ") {
            return (false, token, token.count)
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let punctuation = rest.first, punctuation == "." || punctuation == ")" else { return nil }
        guard rest.dropFirst().isEmpty || rest.dropFirst().hasPrefix(" ") else { return nil }
        return (true, String(digits) + String(punctuation), digits.count + 1)
    }

    /// 引用行的正文。
    private static func quoteBody(_ trimmed: String) -> String {
        let body = trimmed.dropFirst()
        return String(body.hasPrefix(" ") ? body.dropFirst() : body)
    }
}

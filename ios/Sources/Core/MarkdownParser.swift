/**
 * Markdown 解析器 —— 源文 → `[Block]`，纯状态机，不 import SwiftUI / UIKit。
 *
 * 子集：围栏代码块、标题、无序 / 有序列表、引用、分隔线；其余（表格、嵌套列表、任务列表、
 * 脚注、数学、原始 HTML、setext 标题、引用式定义）显示为纯文本。
 * 流式只重解析尾部：新源文是旧源文前缀时搬运冻结段、从冻结边界之后重扫。
 */

import Foundation

// MARK: - 块

/// 一个块级元素。
/// `offset` 是起始行偏移，也是它的身份 —— 渲染层拿它做 key，冻结块的 offset 不变便不重挂载。
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
    /// 行内排版结果（粗体 / 斜体 / 行内码 / 链接），**解析时算一次**。
    /// 渲染层在 `body` 里现调会每帧重跑行内正则，那是滚动掉帧的直接来源；代码块不做行内解析。
    let inline: AttributedString
    /// 起始行偏移 —— 也是这一块的身份。
    let offset: Int
}

extension Block: Identifiable {
    var id: Int { offset }
}

// MARK: - 解析结果

/// 一次解析的结果。除块本身外，另带两件给流式用的记账。
struct MarkdownParseResult: Equatable {
    /// 这次解析对应的源文。`extending` 靠它判断「新源文是不是在旧源文后面接着长」。
    let source: String
    let blocks: [Block]
    /// 前 `frozenCount` 个块已经封口，下次喂新内容时原样搬运、不重解析。
    let frozenCount: Int
    /// 这次从哪个字符偏移开始扫：全量恒为 0，增量等于冻结边界之后第一块的起点。
    let reparsedFrom: Int

    /// 「还没有解析过任何东西」这个单位元。
    ///
    /// 喂给 `parse(_:extending:)` 会自然退化成全量解析：`hasPrefix("")` 恒真、
    /// `resume` 取 `source.count` 即 0、`frozen` 为空 → 从第 0 行扫起。
    /// 所以调用方**不需要**维护「这是不是第一次」—— 首次与后续走同一条路径。
    static let identity = MarkdownParseResult(source: "", blocks: [], frozenCount: 0, reparsedFrom: 0)
}

// MARK: - 解析器

enum MarkdownParser {

    /// 围栏标记。只认三个反引号（`~~~` 不在子集里）。
    private static let fence = "```"

    /// 全量解析。
    static func parse(_ source: String) -> MarkdownParseResult {
        let blocks = scan(lines(of: source), from: 0)
        return MarkdownParseResult(source: source,
                             blocks: blocks,
                             frozenCount: frozenCount(of: source, blocks: blocks),
                             reparsedFrom: 0)
    }

    /// 增量解析：新源文是旧源文的前缀延长时搬运冻结段、只重扫尾部；否则全量重解。
    static func parse(_ source: String, extending previous: MarkdownParseResult) -> MarkdownParseResult {
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
        return MarkdownParseResult(source: source,
                             blocks: blocks,
                             frozenCount: frozenCount(of: source, blocks: blocks),
                             reparsedFrom: resume)
    }

    /// 行内：一段行内 markdown → 富文本。块级自己做，行内交给系统。
    /// `inlineOnlyPreservingWhitespace` 只解行内、空白原样保留，否则系统会重新断行。
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

    /// 按 `\n` 切行并记住起始偏移。`omittingEmptySubsequences: false` 有意 —— 空行是分段依据。
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

    /// 从第 `start` 行开始扫出块；增量解析时它就是冻结边界之后那一行。
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
                let code = content.joined(separator: "\n")
                blocks.append(Block(kind: .code(language: language.isEmpty ? nil : language),
                                    text: code,
                                    inline: AttributedString(code),
                                    offset: line.offset))
                // 没找到闭合就是「还在长」：这一块吃掉剩下的全部
                index = cursor < lines.count ? cursor + 1 : lines.count
                continue
            }

            // 标题
            if let level = headingLevel(of: trimmed) {
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(kind: .heading(level: level), text: text,
                                    inline: attributed(text), offset: line.offset))
                index += 1
                continue
            }

            // 分隔线。**要排在列表前面**：`- - -` 也是分隔线，而按列表记号看它是三项。
            if isDivider(trimmed) {
                blocks.append(Block(kind: .divider, text: "",
                                    inline: AttributedString(""), offset: line.offset))
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
                let quoteText = parts.joined(separator: "\n")
                blocks.append(Block(kind: .quote, text: quoteText,
                                    inline: attributed(quoteText), offset: line.offset))
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
                let itemText = parts.joined(separator: " ")
                blocks.append(Block(kind: .listItem(ordered: marker.ordered, marker: marker.token),
                                    text: itemText,
                                    inline: attributed(itemText),
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
            let paragraph = parts.joined(separator: "\n")
            blocks.append(Block(kind: .paragraph, text: paragraph,
                                inline: attributed(paragraph), offset: line.offset))
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

/**
 * Markdown 解析器的测试（M1–M4）：纯状态机，不 import SwiftUI / UIKit、不碰网络与磁盘，
 * 喂源文、断言块数组，覆盖块级识别 / 行内接入 / 尾部冻结 / 未闭合围栏。
 *
 * 判据与出处：docs/dev/plans/M6-presentation-layer.md §五。
 * 流式语义照上游运行时产物 `@deepseek-ai/dsh-client-ui-primitives` 的 `markdown/incremental.ts`：
 * 除尾部外全部冻结，冻结块的键是源偏移。
 */
import Foundation

@main
struct MarkdownParserTests {

    /// 解析后各块的 kind。
    private static func kinds(_ source: String) -> [Block.Kind] {
        MarkdownParser.parse(source).blocks.map(\.kind)
    }

    private static func texts(_ source: String) -> [String] {
        MarkdownParser.parse(source).blocks.map(\.text)
    }

    static func main() {
        blockSubsets()
        inline()
        tailFreezing()
        openFence()

        print("—— \(passed) passed, \(failed) failed ——")
        if failed > 0 { exit(1) }
    }

    // MARK: - M1 六种子集

    private static func blockSubsets() {
        // 标题：1–6 级各自识别，级别取 `#` 的个数
        for level in 1...6 {
            let mark = String(repeating: "#", count: level)
            expect(kinds("\(mark) 标题") == [.heading(level: level)], "M1a \(level) 级标题")
            expect(texts("\(mark) 标题") == ["标题"], "M1a \(level) 级标题去掉井号与空格")
        }
        // 上限 6 个 `#`
        expect(kinds("####### 七级") == [.paragraph], "M1a 七个井号不是标题")
        // `#` 后面必须有空格（GFM）
        expect(kinds("#话题") == [.paragraph], "M1a 井号后无空格 → 段落")

        expect(kinds("```swift\nlet a = 1\n```") == [.code(language: "swift")], "M1b 围栏代码块带语言")
        expect(texts("```swift\nlet a = 1\n```") == ["let a = 1"], "M1b 代码正文不含围栏行")
        expect(kinds("```\nplain\n```") == [.code(language: nil)], "M1b 围栏代码块无语言")
        expect(texts("```\n甲\n乙\n```") == ["甲\n乙"], "M1b 多行代码保换行")

        // 无序列表：记号原样留给渲染层画圆点
        expect(kinds("- 甲\n- 乙") == [.listItem(ordered: false, marker: "-"), .listItem(ordered: false, marker: "-")], "M1c 无序列表逐项成块")
        expect(texts("- 甲\n- 乙") == ["甲", "乙"], "M1c 无序列表项文本去掉记号")
        expect(kinds("* 甲") == [.listItem(ordered: false, marker: "*")], "M1c 星号也是无序")
        expect(kinds("+ 甲") == [.listItem(ordered: false, marker: "+")], "M1c 加号也是无序")

        // 有序列表：序号原样保留（不从 1 重编）
        expect(kinds("1. 甲\n2. 乙") == [.listItem(ordered: true, marker: "1."), .listItem(ordered: true, marker: "2.")], "M1d 有序列表保留原序号")
        expect(texts("1. 甲\n2. 乙") == ["甲", "乙"], "M1d 有序列表项文本去掉序号")
        expect(kinds("3) 甲") == [.listItem(ordered: true, marker: "3)")], "M1d 右括号也是有序")

        expect(kinds("> 引言\n> 续行") == [.quote], "M1e 连续引用合成一块")
        expect(texts("> 引言\n> 续行") == ["引言\n续行"], "M1e 引用去掉标记、保留分行")

        expect(kinds("---") == [.divider], "M1f 三个减号是分隔线")
        expect(kinds("***") == [.divider], "M1f 三个星号是分隔线")
        expect(kinds("___") == [.divider], "M1f 三个下划线是分隔线")
        expect(kinds("--") == [.paragraph], "M1f 两个减号不是分隔线")

        expect(kinds("普通段落") == [.paragraph], "M1g 单行段落")
        expect(texts("第一行\n第二行") == ["第一行\n第二行"], "M1g 段落内软换行仍是一块")
        expect(texts("甲\n\n乙") == ["甲", "乙"], "M1g 空行分段")

        expect(kinds("# 题\n\n- 项\n\n> 引\n\n---") == [
            .heading(level: 1), .listItem(ordered: false, marker: "-"), .quote, .divider,
        ], "M1h 混合文档按源序出块")
        expect(kinds("") == [], "M1h 空源文无块")
        expect(kinds("\n\n\n") == [], "M1h 全是空行无块")

        // offset = 块起始行的字符偏移（渲染层拿它做 key）
        expect(MarkdownParser.parse("甲\n\n乙").blocks.map(\.offset) == [0, 3], "M1i offset 是起始行偏移")
        expect(MarkdownParser.parse("# 题\n\n正文").blocks.map(\.offset) == [0, 5], "M1i 第二块的 offset 跳过空行")
    }

    // MARK: - M2 行内交给系统

    private static func inline() {
        let rich = MarkdownParser.attributed("**粗** 与 *斜* 与 `码` 与 [链](https://example.com)")

        func intent(containing needle: String) -> InlinePresentationIntent? {
            for run in rich.runs where String(rich[run.range].characters).contains(needle) {
                return run.inlinePresentationIntent
            }
            return nil
        }
        func link(containing needle: String) -> URL? {
            for run in rich.runs where String(rich[run.range].characters).contains(needle) {
                return run.link
            }
            return nil
        }

        expect(intent(containing: "粗")?.contains(.stronglyEmphasized) == true, "M2a 粗体")
        expect(intent(containing: "斜")?.contains(.emphasized) == true, "M2b 斜体")
        expect(intent(containing: "码")?.contains(.code) == true, "M2c 行内码")
        expect(link(containing: "链")?.absoluteString == "https://example.com", "M2d 链接")

        expect(String(rich.characters).contains("**") == false, "M2e 粗体标记已消化")
        expect(String(rich.characters).contains("](") == false, "M2e 链接标记已消化")
        // 纯文本原样返回（不引入额外排版）
        expect(String(MarkdownParser.attributed("就是一句话").characters) == "就是一句话", "M2f 纯文本原样")
    }

    // MARK: - M3 尾部冻结

    private static func tailFreezing() {
        let source = "# 标题\n\n第一段\n\n```swift\nlet a = 1"
        let whole = MarkdownParser.parse(source)

        // M3a：逐字符喂入（最狠的切法），最终结果与全量解析逐块相同 —— 增量正确性的地基。
        var chunked = MarkdownParser.parse("")
        var prefix = ""
        for character in source {
            prefix.append(character)
            chunked = MarkdownParser.parse(prefix, extending: chunked)
        }
        expect(chunked.blocks == whole.blocks, "M3a 逐字符喂入与全量解析一致")

        // M3b：非空源文里只有最后一块是活的，其余冻结
        let head = MarkdownParser.parse("第一段\n\n第二段")
        expect(head.blocks.count == 2, "M3b 两块")
        expect(head.frozenCount == 1, "M3b 尾部之外的块冻结（2 块 → 冻结 1）")

        let grown = MarkdownParser.parse("第一段\n\n第二段还在长", extending: head)
        expect(grown.blocks.prefix(head.frozenCount) == head.blocks.prefix(head.frozenCount), "M3c 冻结块逐字段不变（身份与内容都稳）")
        expect(grown.blocks.last?.text == "第二段还在长", "M3d 尾部跟着长")
        expect(grown.blocks.count == 2, "M3d 还在长时仍是两块（没被空行切开）")

        // M3e：重扫起点 = 冻结边界之后那一块的源偏移，不是 0 —— 即「只重解析尾部」；
        // 取不到尾块用 -1，让断言如实红而不是越界崩。
        let tailOffset = head.blocks.count > 1 ? head.blocks[1].offset : -1
        expect(grown.reparsedFrom == tailOffset, "M3e 从冻结边界之后重扫")
        expect(grown.reparsedFrom == 5, "M3f 重扫起点 = 尾块的源偏移")
        expect(whole.reparsedFrom == 0, "M3f 全量解析从 0 扫")

        // M3g：源文被改写（不是延长）→ 全量重解，不继承
        let rewritten = MarkdownParser.parse("换了个开头\n\n第二段", extending: head)
        expect(rewritten.reparsedFrom == 0, "M3g 源文被改写时不继承")
        expect(rewritten.blocks == MarkdownParser.parse("换了个开头\n\n第二段").blocks, "M3g 结果与全量解析一致")

        // M3h：以空行结尾说明最后一块也封口，可一起冻结
        let sealed = MarkdownParser.parse("第一段\n\n")
        expect(sealed.frozenCount == sealed.blocks.count, "M3h 空行结尾时最后一块也已封口")
        expect(sealed.reparsedFrom == 0, "M3h 全量解析仍从 0 扫")

        // M3i：冻结块的身份（源偏移）在新旧两次解析之间相同 —— 渲染层靠它避免重挂载
        expect(grown.blocks.first?.offset == head.blocks.first?.offset, "M3i 首块身份稳定")

        expect(MarkdownParser.parse(source, extending: whole).blocks == whole.blocks, "M3j 重放结果不变")

        expect(MarkdownParser.parse("", extending: MarkdownParser.parse("")).blocks == [], "M3k 空源文续接")
    }

    // MARK: - M4 未闭合围栏

    private static func openFence() {
        let justOpened = MarkdownParser.parse("```swift")
        expect(justOpened.blocks.count == 1, "M4a 只有围栏开头也是一块")
        expect(kinds("```swift") == [.code(language: "swift")], "M4a 未闭合也识别为代码块，不是段落")
        expect(texts("```swift") == [""], "M4a 空代码正文")

        let open = MarkdownParser.parse("```swift\nlet a = 1")
        expect(kinds("```swift\nlet a = 1") == [.code(language: "swift")], "M4b 未闭合围栏按代码块渲染")
        expect(texts("```swift\nlet a = 1") == ["let a = 1"], "M4b 半截代码正文")

        // 补上闭合标记 → 仍是同一个块
        let closed = MarkdownParser.parse("```swift\nlet a = 1\n```", extending: open)
        expect(closed.blocks.count == 1, "M4c 闭合后仍是同一块")
        expect(closed.blocks.first?.offset == open.blocks.first?.offset, "M4d 身份（源偏移）不变")
        expect(closed.blocks.first?.kind == .code(language: "swift"), "M4d 语言不变")
        expect(closed.blocks.first?.text == "let a = 1", "M4e 闭合标记不进正文")

        let more = MarkdownParser.parse("```swift\nlet a = 1\n```\n\n下一段", extending: closed)
        expect(more.blocks.count == 2, "M4f 闭合后可接新块")
        expect(more.blocks.first?.kind == .code(language: "swift"), "M4f 首块仍是那个代码块")
        expect(more.blocks.first?.offset == closed.blocks.first?.offset, "M4f 首块身份不变")
        expect(more.blocks.last?.kind == .paragraph, "M4g 后续是段落")

        // 未闭合期间的中间态也走代码块（不先按段落、闭合后再跳）
        var growing = MarkdownParser.parse("")
        var text = ""
        for line in ["```", "甲", "乙"] {
            text += (text.isEmpty ? "" : "\n") + line
            growing = MarkdownParser.parse(text, extending: growing)
            expect(growing.blocks.count == 1 && growing.blocks.first?.kind == .code(language: nil), "M4h 生长中一直是代码块（\(line)）")
        }
    }
}

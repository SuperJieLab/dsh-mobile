/**
 * Markdown 解析器的测试：纯状态机，不 import SwiftUI / UIKit、不碰网络与磁盘，
 * 喂源文、断言块数组，覆盖块级识别 / 行内接入 / 尾部冻结 / 未闭合围栏。
 *
 * 解析器住 `Sources/Core/MarkdownParser.swift`（变化原因是载体标准，
 * 不是某一屏的状态），这些断言因此也不依赖任何界面。
 * 流式语义照上游运行时产物 `@deepseek-ai/dsh-client-ui-primitives` 的 `markdown/incremental.ts`：
 * 除尾部外全部冻结，冻结块的键是源偏移。
 */
import Foundation
import XCTest

@testable import DshMobile

final class MarkdownParserTests: XCTestCase {

    /// 解析缓存不改变结果，也不把不同源文串起来。
    ///
    /// 它守的是「缓存是纯加速」这一半 —— 命中与不命中给出的块数组必须一模一样；
    /// 至于「真的命中了」（省掉了那次解析），缓存不可注入，测不到，只能靠代码审查。
    func testParseCacheIsTransparent() {
        let first = "# 标题\n\n一段内容"
        let second = "另一段\n\n- 列表项"
        let a1 = MarkdownParseCache.result(for: first)
        let a2 = MarkdownParseCache.result(for: first)
        let b = MarkdownParseCache.result(for: second)
        XCTAssertEqual(a1, a2, "同一段源文两次取到同一结果")
        XCTAssertEqual(a1, MarkdownParser.parse(first), "命中与直接解析结果一致")
        XCTAssertNotEqual(a1, b, "不同源文不串")
    }

    /// 解析后各块的 kind。
    private func kinds(_ source: String) -> [Block.Kind] {
        MarkdownParser.parse(source).blocks.map(\.kind)
    }

    private func texts(_ source: String) -> [String] {
        MarkdownParser.parse(source).blocks.map(\.text)
    }

    func testParse() {
        blockSubsets()
        inline()
        tailFreezing()
        openFence()
    }

    // MARK: - 六种子集

    private func blockSubsets() {
        // 标题：1–6 级各自识别，级别取 `#` 的个数
        for level in 1...6 {
            let mark = String(repeating: "#", count: level)
            XCTAssertTrue(kinds("\(mark) 标题") == [.heading(level: level)], "M1a \(level) 级标题")
            XCTAssertTrue(texts("\(mark) 标题") == ["标题"], "M1a \(level) 级标题去掉井号与空格")
        }
        // 上限 6 个 `#`
        XCTAssertTrue(kinds("####### 七级") == [.paragraph], "M1a 七个井号不是标题")
        // `#` 后面必须有空格（GFM）
        XCTAssertTrue(kinds("#话题") == [.paragraph], "M1a 井号后无空格 → 段落")

        XCTAssertTrue(kinds("```swift\nlet a = 1\n```") == [.code(language: "swift")], "M1b 围栏代码块带语言")
        XCTAssertTrue(texts("```swift\nlet a = 1\n```") == ["let a = 1"], "M1b 代码正文不含围栏行")
        XCTAssertTrue(kinds("```\nplain\n```") == [.code(language: nil)], "M1b 围栏代码块无语言")
        XCTAssertTrue(texts("```\n甲\n乙\n```") == ["甲\n乙"], "M1b 多行代码保换行")

        // 无序列表：记号原样留给渲染层画圆点
        XCTAssertTrue(kinds("- 甲\n- 乙") == [.listItem(ordered: false, marker: "-"), .listItem(ordered: false, marker: "-")], "M1c 无序列表逐项成块")
        XCTAssertTrue(texts("- 甲\n- 乙") == ["甲", "乙"], "M1c 无序列表项文本去掉记号")
        XCTAssertTrue(kinds("* 甲") == [.listItem(ordered: false, marker: "*")], "M1c 星号也是无序")
        XCTAssertTrue(kinds("+ 甲") == [.listItem(ordered: false, marker: "+")], "M1c 加号也是无序")

        // 有序列表：序号原样保留（不从 1 重编）
        XCTAssertTrue(kinds("1. 甲\n2. 乙") == [.listItem(ordered: true, marker: "1."), .listItem(ordered: true, marker: "2.")], "M1d 有序列表保留原序号")
        XCTAssertTrue(texts("1. 甲\n2. 乙") == ["甲", "乙"], "M1d 有序列表项文本去掉序号")
        XCTAssertTrue(kinds("3) 甲") == [.listItem(ordered: true, marker: "3)")], "M1d 右括号也是有序")

        XCTAssertTrue(kinds("> 引言\n> 续行") == [.quote], "M1e 连续引用合成一块")
        XCTAssertTrue(texts("> 引言\n> 续行") == ["引言\n续行"], "M1e 引用去掉标记、保留分行")

        XCTAssertTrue(kinds("---") == [.divider], "M1f 三个减号是分隔线")
        XCTAssertTrue(kinds("***") == [.divider], "M1f 三个星号是分隔线")
        XCTAssertTrue(kinds("___") == [.divider], "M1f 三个下划线是分隔线")
        XCTAssertTrue(kinds("--") == [.paragraph], "M1f 两个减号不是分隔线")

        XCTAssertTrue(kinds("普通段落") == [.paragraph], "M1g 单行段落")
        XCTAssertTrue(texts("第一行\n第二行") == ["第一行\n第二行"], "M1g 段落内软换行仍是一块")
        XCTAssertTrue(texts("甲\n\n乙") == ["甲", "乙"], "M1g 空行分段")

        XCTAssertTrue(kinds("# 题\n\n- 项\n\n> 引\n\n---") == [
            .heading(level: 1), .listItem(ordered: false, marker: "-"), .quote, .divider,
        ], "M1h 混合文档按源序出块")
        XCTAssertTrue(kinds("") == [], "M1h 空源文无块")
        XCTAssertTrue(kinds("\n\n\n") == [], "M1h 全是空行无块")

        // offset = 块起始行的字符偏移（渲染层拿它做 key）
        XCTAssertTrue(MarkdownParser.parse("甲\n\n乙").blocks.map(\.offset) == [0, 3], "M1i offset 是起始行偏移")
        XCTAssertTrue(MarkdownParser.parse("# 题\n\n正文").blocks.map(\.offset) == [0, 5], "M1i 第二块的 offset 跳过空行")
    }

    // MARK: - 行内交给系统

    private func inline() {
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

        XCTAssertTrue(intent(containing: "粗")?.contains(.stronglyEmphasized) == true, "M2a 粗体")
        XCTAssertTrue(intent(containing: "斜")?.contains(.emphasized) == true, "M2b 斜体")
        XCTAssertTrue(intent(containing: "码")?.contains(.code) == true, "M2c 行内码")
        XCTAssertTrue(link(containing: "链")?.absoluteString == "https://example.com", "M2d 链接")

        XCTAssertTrue(String(rich.characters).contains("**") == false, "M2e 粗体标记已消化")
        XCTAssertTrue(String(rich.characters).contains("](") == false, "M2e 链接标记已消化")
        // 纯文本原样返回（不引入额外排版）
        XCTAssertTrue(String(MarkdownParser.attributed("就是一句话").characters) == "就是一句话", "M2f 纯文本原样")
    }

    // MARK: - 尾部冻结

    private func tailFreezing() {
        let source = "# 标题\n\n第一段\n\n```swift\nlet a = 1"
        let whole = MarkdownParser.parse(source)

        // M3a：逐字符喂入（最狠的切法），最终结果与全量解析逐块相同 —— 增量正确性的地基。
        var chunked = MarkdownParser.parse("")
        var prefix = ""
        for character in source {
            prefix.append(character)
            chunked = MarkdownParser.parse(prefix, extending: chunked)
        }
        XCTAssertTrue(chunked.blocks == whole.blocks, "M3a 逐字符喂入与全量解析一致")

        // M3b：非空源文里只有最后一块是活的，其余冻结
        let head = MarkdownParser.parse("第一段\n\n第二段")
        XCTAssertTrue(head.blocks.count == 2, "M3b 两块")
        XCTAssertTrue(head.frozenCount == 1, "M3b 尾部之外的块冻结（2 块 → 冻结 1）")

        let grown = MarkdownParser.parse("第一段\n\n第二段还在长", extending: head)
        XCTAssertTrue(grown.blocks.prefix(head.frozenCount) == head.blocks.prefix(head.frozenCount), "M3c 冻结块逐字段不变（身份与内容都稳）")
        XCTAssertTrue(grown.blocks.last?.text == "第二段还在长", "M3d 尾部跟着长")
        XCTAssertTrue(grown.blocks.count == 2, "M3d 还在长时仍是两块（没被空行切开）")

        // M3e：重扫起点 = 冻结边界之后那一块的源偏移，不是 0 —— 即「只重解析尾部」；
        // 取不到尾块用 -1，让断言如实红而不是越界崩。
        let tailOffset = head.blocks.count > 1 ? head.blocks[1].offset : -1
        XCTAssertTrue(grown.reparsedFrom == tailOffset, "M3e 从冻结边界之后重扫")
        XCTAssertTrue(grown.reparsedFrom == 5, "M3f 重扫起点 = 尾块的源偏移")
        XCTAssertTrue(whole.reparsedFrom == 0, "M3f 全量解析从 0 扫")

        // M3g：源文被改写（不是延长）→ 全量重解，不继承
        let rewritten = MarkdownParser.parse("换了个开头\n\n第二段", extending: head)
        XCTAssertTrue(rewritten.reparsedFrom == 0, "M3g 源文被改写时不继承")
        XCTAssertTrue(rewritten.blocks == MarkdownParser.parse("换了个开头\n\n第二段").blocks, "M3g 结果与全量解析一致")

        // M3h：以空行结尾说明最后一块也封口，可一起冻结
        let sealed = MarkdownParser.parse("第一段\n\n")
        XCTAssertTrue(sealed.frozenCount == sealed.blocks.count, "M3h 空行结尾时最后一块也已封口")
        XCTAssertTrue(sealed.reparsedFrom == 0, "M3h 全量解析仍从 0 扫")

        // M3i：冻结块的身份（源偏移）在新旧两次解析之间相同 —— 渲染层靠它避免重挂载
        XCTAssertTrue(grown.blocks.first?.offset == head.blocks.first?.offset, "M3i 首块身份稳定")

        XCTAssertTrue(MarkdownParser.parse(source, extending: whole).blocks == whole.blocks, "M3j 重放结果不变")

        XCTAssertTrue(MarkdownParser.parse("", extending: MarkdownParser.parse("")).blocks == [], "M3k 空源文续接")
    }

    // MARK: - 未闭合围栏

    private func openFence() {
        let justOpened = MarkdownParser.parse("```swift")
        XCTAssertTrue(justOpened.blocks.count == 1, "M4a 只有围栏开头也是一块")
        XCTAssertTrue(kinds("```swift") == [.code(language: "swift")], "M4a 未闭合也识别为代码块，不是段落")
        XCTAssertTrue(texts("```swift") == [""], "M4a 空代码正文")

        let open = MarkdownParser.parse("```swift\nlet a = 1")
        XCTAssertTrue(kinds("```swift\nlet a = 1") == [.code(language: "swift")], "M4b 未闭合围栏按代码块渲染")
        XCTAssertTrue(texts("```swift\nlet a = 1") == ["let a = 1"], "M4b 半截代码正文")

        // 补上闭合标记 → 仍是同一个块
        let closed = MarkdownParser.parse("```swift\nlet a = 1\n```", extending: open)
        XCTAssertTrue(closed.blocks.count == 1, "M4c 闭合后仍是同一块")
        XCTAssertTrue(closed.blocks.first?.offset == open.blocks.first?.offset, "M4d 身份（源偏移）不变")
        XCTAssertTrue(closed.blocks.first?.kind == .code(language: "swift"), "M4d 语言不变")
        XCTAssertTrue(closed.blocks.first?.text == "let a = 1", "M4e 闭合标记不进正文")

        let more = MarkdownParser.parse("```swift\nlet a = 1\n```\n\n下一段", extending: closed)
        XCTAssertTrue(more.blocks.count == 2, "M4f 闭合后可接新块")
        XCTAssertTrue(more.blocks.first?.kind == .code(language: "swift"), "M4f 首块仍是那个代码块")
        XCTAssertTrue(more.blocks.first?.offset == closed.blocks.first?.offset, "M4f 首块身份不变")
        XCTAssertTrue(more.blocks.last?.kind == .paragraph, "M4g 后续是段落")

        // 未闭合期间的中间态也走代码块（不先按段落、闭合后再跳）
        var growing = MarkdownParser.parse("")
        var text = ""
        for line in ["```", "甲", "乙"] {
            text += (text.isEmpty ? "" : "\n") + line
            growing = MarkdownParser.parse(text, extending: growing)
            XCTAssertTrue(growing.blocks.count == 1 && growing.blocks.first?.kind == .code(language: nil), "M4h 生长中一直是代码块（\(line)）")
        }
    }
}

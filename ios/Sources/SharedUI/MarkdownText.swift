import SwiftUI

/// 助手文本的渲染：`[Block]` → 视图。
///
/// 它**只认 `[Block]`，不认 markdown 源文** —— 解析与渲染分层隔离，将来若把自写解析器
/// 换成成熟库（触发条件见 `docs/dev/plans/M6-presentation-layer.md` §3.3 决定 15），
/// 换掉的是 `MarkdownParser` 那一层，这里一行都不用动。
///
/// ## 流式：解析结果随源文增量演进
///
/// 正文在瞬态通道上逐 chunk 增长（M2 的打字机）。这里的做法是：
///
/// - 解析结果放在 `@State` 里，**只在视图第一次出现时全量解析**（`State(initialValue:)`
///   在身份不变的重建里会被忽略 —— 于是父视图每次重算 body 都不会重解析）。
/// - 源文变化时走 `MarkdownParser.parse(_:extending:)`：**已冻结的块原样搬运，只重解析尾部**。
/// - 块的 `id` 是它的源偏移，冻结块的 id 不变 ⇒ SwiftUI 不重挂载那一行，界面不闪（判据 M3/R4）。
///
/// ## 行内交给系统，块级自己画
///
/// 行内（粗体 / 斜体 / 行内码 / 链接）由 `MarkdownParser.attributed` 交给系统的
/// `AttributedString(markdown:)`；块级的排版（标题字号、代码块、列表圆点与序号、引用竖线、
/// 分隔线）必须自己画 —— 系统在 `Text` 上不做块级排版。
struct MarkdownText: View {
    let source: String

    @State private var parse: MarkdownParse

    init(source: String) {
        self.source = source
        _parse = State(initialValue: MarkdownParser.parse(source))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parse.blocks) { block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: source) { _, grown in
            parse = MarkdownParser.parse(grown, extending: parse)
        }
    }
}

/// 一个块的呈现。块的种类只有六种（`Block.Kind`），这里是它们各自的画法。
private struct BlockView: View {
    let block: Block

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(MarkdownParser.attributed(block.text))
                .font(Self.font(for: level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph:
            Text(MarkdownParser.attributed(block.text))

        case .code(let language):
            CodeBlockView(language: language, code: block.text)

        case .listItem(_, let marker):
            // 圆点与序号自己画 —— 系统的行内解析不给这个，这也是「块级必须自己做」的原因。
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(MarkdownParser.attributed(block.text))
            }

        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                Text(MarkdownParser.attributed(block.text))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)

        case .divider:
            Divider()
        }
    }

    /// 标题的字号阶梯。用的是动态字体，跟着系统的辅助功能字号走。
    private static func font(for level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        case 4: return .subheadline
        default: return .footnote
        }
    }
}

/// 围栏代码块：等宽、带底、可横向滚动（长行不折行、不撑破窄屏）。
///
/// 语言标记只用来留痕（放右上角的小字）—— 本期不做语法高亮（§1.3 不做清单）。
private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 比助手气泡的底色再退一档，于是「块里嵌块」看得出边界（气泡是 secondary）。
        .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 8))
    }
}

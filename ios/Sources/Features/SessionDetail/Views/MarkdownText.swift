import SwiftUI

/// 助手文本的渲染：`[Block]` → 视图。它**只认 `[Block]`，不认 markdown 源文** ——
/// 换成成熟库时换的是 `MarkdownParser` 那一层，这里一行都不用动。
/// **流式**：源文逐 chunk 增长时走 `parse(_:extending:)`（冻结块搬运、只重解析尾部）。
/// ⚠️ **`@State(initialValue:)` 只挡住「赋值」，挡不住「求值」**：它的参数每次视图重建都
/// 求一次值，所以解析结果要有这一层缓存兜着。
enum MarkdownParseCache {

    private static let limit = 64
    private static var store: [String: MarkdownParseResult] = [:]
    private static var order: [String] = []
    private static let lock = NSLock()

    static func result(for source: String) -> MarkdownParseResult {
        lock.lock()
        if let hit = store[source] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // 解析放在锁外：它可能很久，不该挡住别的视图取缓存。
        let parse = MarkdownParser.parse(source)

        lock.lock()
        // 双检：解析期间别的线程可能已经填上了同一段。
        if let hit = store[source] {
            lock.unlock()
            return hit
        }
        store[source] = parse
        order.append(source)
        if order.count > limit {
            store.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return parse
    }
}

struct MarkdownText: View {
    let source: String

    @State private var parse: MarkdownParseResult

    /// - Parameter caching: 已完成的消息传 `true`（同一段源文只解析一次）；
    ///   流式内容传 `false` —— 它每个 chunk 换一份源文，缓存只会写一堆用不上的中间态。
    init(source: String, caching: Bool = true) {
        self.source = source
        _parse = State(initialValue: caching
            ? MarkdownParseCache.result(for: source)
            : MarkdownParser.parse(source))
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
            Text(block.inline)
                .font(Self.font(for: level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph:
            Text(block.inline)

        case .code(let language):
            CodeBlockView(language: language, code: block.text)

        case .listItem(_, let marker):
            // 圆点与序号自己画 —— 系统的行内解析不给这个，这也是「块级必须自己做」的原因。
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(block.inline)
            }

        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                Text(block.inline)
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

/// 围栏代码块：等宽、带底、可横向滚动（长行不折行）。语言标记只用来留痕（右上角小字）——
/// 本期不做高亮。
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

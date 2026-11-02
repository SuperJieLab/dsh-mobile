/**
 * 工作空间名字的规则：trim 之后非空、不含路径分隔符、不是 `.` 或 `..`。
 *
 * 纯规则 —— 入参就是全部输入，没有状态、不认识网络与视图。网关侧有一份同样的实现
 * （手机上要在提交前就拦下、不发请求；服务端不信任客户端，所以两边都必须有），
 * 两份靠同一组样本对齐。
 *
 * 这里只回答「能不能用、为什么不能用」；**提示语归视图**（判定层不放用户可见的中文）。
 */
import Foundation

enum WorkspaceName {

    /// 名字不能用的理由。
    enum Problem: Equatable {
        case blank
        case pathSeparator
        case dotEntry
    }

    /// 要用的名字：去掉首尾空白。内部空格是名字的一部分，不动。
    ///
    /// 集合里补了 BOM（U+FEFF）：JS 的 `trim()` 会去掉它，而 `.whitespacesAndNewlines`
    /// 不含它。两侧规则要逐项等价 —— 否则一个肉眼看不见的 BOM 会让客户端放行、服务端拒绝，
    /// 用户看到一个看不懂的失败。
    static func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: trimmedCharacters)
    }

    private static let trimmedCharacters: CharacterSet =
        CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    /**
     * 预填一个名字：`workspace-N`，取**已注册**的那些里第一个空闲的。
     *
     * 「空闲」只看得到已注册的工作空间 —— 根下还没注册的目录看不见。那种情况交给服务端撞：
     * 目录已在时它会把那个目录注册上（`created` 为真），用户得到一个同名的既有目录，
     * 也比让他从零想一个名字好。
     *
     * @param registered - 已注册的工作空间标题。
     */
    static func suggestion(among registered: [String]) -> String {
        let taken = Set(registered)
        var index = 1
        while taken.contains("workspace-\(index)") { index += 1 }
        return "workspace-\(index)"
    }

    /**
     * 这个名字能不能用。
     *
     * @param raw - 用户输入的原样。
     * @returns `nil` 表示可以用；否则是理由。
     */
    static func problem(with raw: String) -> Problem? {
        let name = trimmed(raw)
        if name.isEmpty { return .blank }
        if name == "." || name == ".." { return .dotEntry }
        if name.contains("/") || name.contains("\\") { return .pathSeparator }
        return nil
    }
}

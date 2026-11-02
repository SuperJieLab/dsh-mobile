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
    static func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

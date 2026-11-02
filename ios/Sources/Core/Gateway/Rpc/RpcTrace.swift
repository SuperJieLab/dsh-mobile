/**
 * 一次请求的关联标记 —— 两端靠它把同一次操作的日志对上。
 *
 * 为什么需要：网关同时服务多个请求，日志交错写在一起；客户端也可能并发发几条。没有标记时，
 * 「这一次工作空间创建为什么失败」只能靠时间接近去猜，并发两件事就分不开。
 *
 * 形状最小：一个短字符串，随请求头走，两端各自记在自己的行里。**不是** W3C trace context ——
 * 我们没有跨进程的 span 树，那套东西在这里只会多一层没人读的结构。
 *
 * 用 `@TaskLocal` 而不是参数：要传它的地方有十几层（每个 op 的包装函数、传输层、状态层），
 * 逐层传参的代价远大于收益，而且每一处都可能漏传。`TaskLocal` 在 async 边界上正确传播，
 * 出了作用域自动消失。
 */
import Foundation

enum RpcTrace {

    /// 与网关侧 `requestIdOf` 读的头名必须一致。
    static let headerName = "X-Dsh-Request-Id"

    /// 当前异步任务链上那次请求的 id。作用域外为 `nil`（启动、后台任务、测试）。
    @TaskLocal static var requestId: String?

    /**
     * 在一个新的标记下执行，并把 id 交给 `body` 放进请求头。
     *
     * 作用域覆盖 `body` 的全部：包装函数在 `perform` 之后打的那条成功日志也因此带标记。
     *
     * @param body - 这次请求的全部工作，参数是要写进头的那个 id。
     */
    static func withNewId<T>(_ body: (String) async throws -> T) async rethrows -> T {
        let id = newId()
        return try await $requestId.withValue(id) { try await body(id) }
    }

    /// 8 位随机串。短是为了不把每一行撑宽；它不是凭证，不需要不可猜。
    static func newId() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// 行首标记；不在作用域里时为空串，行格式与从前一致。
    static var lineMarker: String {
        guard let id = requestId else { return "" }
        return " [req=\(id)]"
    }
}

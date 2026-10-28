/**
 * 命令目录的三面与过滤 —— 一次取数的**全部**结果，外加命令通道的两个调用
 * （`fetchCommands` 列目录、`runCommand` 执行一整行）。
 *
 * 三面与 `ModelCatalogState` 同构（等待 / 有内容 / 失败 + 原因），差别只在失败面带的是
 * 协议拒绝的原文而不是一句拼好的话：说法随产品变，原因随协议变。
 *
 * **不缓存跨会话**：命令集是 per-agent 的，还会随插件装卸变；把上一份留给下一次打开
 * 就等于显示一个已经不作数的列表。所以每次打开都重新取，失败就说失败。
 */
import Foundation

@MainActor
@Observable
final class CommandDirectory {

    /// 屏幕上要落成的三种面。
    enum Outcome: Equatable {
        /// 还没有结果，或正在重拉 —— 「等待」不是「没有命令」。
        case waiting
        /// 拿到了。空数组是成功面（这个会话真没有命令），由视图补一句。
        case ready([CommandInfo])
        /// 没拿到。原因只有两档，分法与状态行的失败同源。
        case failed(Cause)
    }

    /// 失败的原因。**不带句子**：说给用户听的那句在 `Display/CommandText.swift`。
    enum Cause: Equatable {
        /// 服务端按信封拒绝 —— 协议值原样带。
        case refused(GatewayFailure)
        /// 没连上网关（传输失败、组网未激活、身份不可用）。
        case offline
    }

    private(set) var outcome: Outcome = .waiting

    private let fetch: @MainActor () async throws -> [CommandInfo]

    /// 本机发起过的最新一次取数代号：打开面板与重试可能前后脚触发，晚到的旧回包不许覆盖。
    private var generation = 0

    init(fetch: @escaping @MainActor () async throws -> [CommandInfo]) {
        self.fetch = fetch
    }

    /// 取一次。重试也走这里：先把面置回等待，避免「旧列表还挂着，看不出在重拉」。
    func reload() async {
        generation += 1
        let mine = generation
        outcome = .waiting
        do {
            let commands = try await fetch()
            guard mine == generation else { return }
            outcome = .ready(commands)
        } catch let error as RpcClientError {
            guard mine == generation else { return }
            if case .refused(let failure) = error {
                outcome = .failed(.refused(failure))
            } else {
                outcome = .failed(.offline)
            }
        } catch {
            guard mine == generation else { return }
            outcome = .failed(.offline)
        }
    }

    /// 按名字过滤。大小写不敏感的前缀匹配优先，其次是包含匹配，同档保持宿主给的顺序
    /// （宿主已按名字排好）。空查询返回全部 —— 刚敲 `/` 时应当看得见所有能用的命令。
    ///
    /// 只匹配名字、不匹配说明：说明是给人读的一句话，拿它参与匹配会让「敲了 `per` 却命中
    /// 一条名字完全无关的命令」变成常态。
    static func match(_ commands: [CommandInfo], query: String) -> [CommandInfo] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return commands }
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(needle) }
        let contains = commands.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }
        return prefix + contains
    }
}

/// 列该会话此刻能用的命令。**每次打开面板都拉**：命令集是 per-agent 的，
/// 随插件装卸与作用域变，不缓存成常量。
@MainActor
func fetchCommands(_ client: RpcClient, sessionId: String) async throws -> [CommandInfo] {
    let response: CommandCatalogResponse = try await client.perform(
        CommandCatalogRequest(sessionId: sessionId)
    )
    // 缺载荷抛错，不填空数组 —— 理由见 `RpcClientError.malformedResponse`。
    guard let commands = response.commands else {
        throw RpcClientError.malformedResponse(detail: "commands")
    }
    return commands
}

/// 执行一整行命令。`ok` = **已受理**，结果从订阅流里的
/// `command/run` / `command/done` 来 —— 这个回包不带执行结果。
///
/// 回包里的 `commandId` 不返回：这一版没有一处按它对账（结果靠流里那个与 `command/run`
/// 配对）。但它**必须有** —— 缺载荷就抛错。
@MainActor
func runCommand(_ client: RpcClient, sessionId: String, line: String) async throws {
    let response: CommandExecuteResponse = try await client.perform(
        CommandExecuteRequest(sessionId: sessionId, line: line)
    )
    guard response.commandId != nil else {
        throw RpcClientError.malformedResponse(detail: "commandId")
    }
}

/**
 * 命令目录的三面与过滤 —— 一次取数的**全部**结果，视图只读它。
 *
 * 与 `ModelCatalogState` 同构（等待 / 有内容 / 失败 + 原因），差别只在失败面带的是
 * 协议拒绝的原文而不是一句拼好的话：说法随产品变，原因随协议变。
 *
 * **不缓存跨会话**：命令集是 per-agent 的，还会随插件装卸变；把上一份留给下一次打开
 * 就等于显示一个已经不作数的列表。所以每次打开都重新取，失败就说失败。
 */
import Combine
import Foundation

@MainActor
final class CommandDirectory: ObservableObject {

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

    @Published private(set) var outcome: Outcome = .waiting

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
        } catch let error as GatewayClientError {
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
func fetchCommands(_ client: GatewayClient, sessionId: String) async throws -> [CommandInfo] {
    let response: CommandCatalogResponse = try await client.perform(
        CommandCatalogRequest(sessionId: sessionId)
    )
    // `ok: true` 却没有载荷是服务端的错，不该被默认值悄悄盖过去 —— 那会把一次应答异常
    // 显示成「这个会话没有可用的命令」（成功面），用户以为真没有。
    guard let commands = response.commands else {
        throw GatewayClientError.malformedResponse(detail: "commands")
    }
    return commands
}

/// 执行一整行命令。`ok` = **已受理**，结果从订阅流里的
/// `command/run` / `command/done` 来 —— 这个回包不带执行结果。
///
/// 返回 `commandId` 只为了给调用方留一条可对账的线，不是结果。
@MainActor
@discardableResult
func runCommand(_ client: GatewayClient, sessionId: String, line: String) async throws -> String {
    let response: CommandExecuteResponse = try await client.perform(
        CommandExecuteRequest(sessionId: sessionId, line: line)
    )
    guard let commandId = response.commandId else {
        throw GatewayClientError.malformedResponse(detail: "commandId")
    }
    return commandId
}

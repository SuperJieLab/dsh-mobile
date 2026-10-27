/**
 * 模型目录的取数与三种面 —— 一次取数的**全部**结果，视图只读它。
 *
 * 三种面与列表同构：有内容 / 失败 / 等待。差别只在失败面带的是**原因**（协议拒绝时原样带
 * `GatewayFailure`，句子在 `Display/CatalogText.swift`），不是一句拼好的话 —— 说法随产品
 * 决定变，原因随协议变，两者不同源。
 *
 * 取数入口是注入的闭包而不是 `RpcClient`：这条链上没有一条断言需要起网关，
 * 而「三面怎么映射」正是唯一要钉住的判定。
 *
 * 触发点不在这里：打开菜单时现拉一次、不订阅刷新 —— 目录只在凭证 / 适配器变更时才变。
 */
import Foundation

@MainActor
@Observable
final class ModelCatalogState {

    /// 屏幕上要落成的三种面。
    enum Outcome: Equatable {
        /// 还没有结果，或正在重拉 —— 「等待」不是「空目录」。
        case waiting
        /// 拿到了目录。`groups` 为空是成功面，由视图补一句「没有可用的模型」。
        case ready(ModelCatalog)
        /// 没拿到。原因只有两档，分法与状态行的失败同源。
        case failed(Cause)
    }

    /// 失败的原因。**不带句子**：说给用户听的那两句在 `Display/CatalogText.swift`。
    enum Cause: Equatable {
        /// 服务端按信封拒绝 —— 协议值原样带，原文怎么读由显示层定。
        case refused(GatewayFailure)
        /// 没连上网关（传输失败、组网未激活、身份不可用）。
        case offline
    }

    private(set) var outcome: Outcome = .waiting

    /// 上一次成功拿到的目录默认值。**只为按钮标题**：重拉期间 `outcome` 回到 `.waiting`，
    /// 而按钮不该因为「重新取一次」把模型名闪成「未知」。
    private(set) var lastKnownDefault: ModelSelection?

    private let fetch: @MainActor () async throws -> ModelCatalog

    /// 本机发起过的最新一次取数代号 —— `.task` 与「重试」可能前后脚触发两次，
    /// 迟到的旧回包不许覆盖新结果（与 `ModelSelectionState` 的代号纪律同源）。
    private var generation = 0

    init(fetch: @escaping @MainActor () async throws -> ModelCatalog) {
        self.fetch = fetch
    }

    /// 取一次。重试也走这里：先把面置回等待，避免「旧目录还挂着，看不出在重拉」。
    func reload() async {
        generation += 1
        let mine = generation
        outcome = .waiting
        do {
            let list = try await fetch()
            guard mine == generation else { return }
            lastKnownDefault = list.default
            outcome = .ready(list)
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
}

/// 拉模型目录：打开选择器时现拉一次，不订阅刷新 —— 重开即新。
///
/// 它是 `ModelCatalogState` 的取数入口（构造时作为闭包注入），所以与它同住一个文件：
/// 「取回来什么」与「取回来落成哪三面」是同一件事的上下游。
@MainActor
func fetchCatalog(_ client: RpcClient) async throws -> ModelCatalog {
    let response: ModelCatalogResponse = try await client.perform(ModelCatalogRequest())
    // 协议里的分组与命名原样交给上层 —— 这里不改写、不补默认。
    return ModelCatalog(
        default: response.default,
        groups: response.groups,
        failures: response.failures
    )
}

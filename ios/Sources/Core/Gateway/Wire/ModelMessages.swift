/**
 * 模型选择的载荷。与链路无关：请求参数在这里，响应里的目录也在这里。
 */
import Foundation

/// 一次模型选择。`reasoningEffort` 缺省 = 不指定推理力度 ——
/// 字段缺省是协议的一部分（`encodeIfPresent`），不是故障。
struct ModelSelection: Codable, Equatable {
    let provider: String
    let model: String
    var reasoningEffort: String? = nil
}

/// 打开选择器时现拉一次的目录。服务端只转发与剥除宿主私有字段，
/// 不重排不补齐；`default` 整个缺省 = 无部署默认，客户端显示时不猜。

struct ModelCatalog: Decodable, Equatable {
    var `default`: ModelSelection? = nil
    var groups: [ModelCatalogGroup]? = nil
    var failures: [ModelCatalogFailure]? = nil
}

/// 目录里的一个 provider 分组。

struct ModelCatalogGroup: Decodable, Equatable {
    let id: String
    let name: String
    let models: [ModelCatalogEntry]
}

/// 分组里的一个可选项。`reasoning` 缺省 = 该模型不暴露推理力度选择。

struct ModelCatalogEntry: Decodable, Equatable {
    let id: String
    let name: String
    var reasoning: Reasoning? = nil

    /// 上游形状：`efforts` 是**对象数组**（每项有 `id` 与 `name`），不是 id 串 ——
    /// 按 `[String]` 解会让整份目录解码失败、菜单全空。
    struct Reasoning: Decodable, Equatable {
        let efforts: [Effort]
        var defaultEffort: String? = nil

        struct Effort: Decodable, Equatable {
            let id: String
            let name: String
            var description: String? = nil
        }
    }
}

/// 目录里的一个拉取失败的 provider —— 失败隔离，不炸整体（上游同语义）。

struct ModelCatalogFailure: Decodable, Equatable {
    let id: String
    let name: String
    let message: String
}

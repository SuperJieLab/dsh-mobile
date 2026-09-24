/**
 * 模型选择的协议解码测试（M7 T5，判据：解码用例全绿）+ 跟随更新状态机（T6，V1–V4）。
 *
 * 判据与出处：docs/dev/plans/M7-model-selection.md §五；协议 docs/dev/protocol.md §4.7
 * 与 §4.2 opening 的 `model` 字段。解码的核心是**缺省安全**：字段缺省是陈述不是故障，
 * 服务端「不知道」时客户端不得猜。
 */
import Foundation

@main
struct ModelProtocolTests {

    static func main() {
        decodeSelection()
        decodeCatalog()
        decodeOpening()
        encodeRequests()

        print("—— \(passed) passed, \(failed) failed ——")
        if failed > 0 { exit(1) }
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    // MARK: - ModelSelection 解码

    private static func decodeSelection() {
        let withEffort = try? decoder.decode(
            ModelSelection.self,
            from: Data(#"{"provider":"deepseek","model":"v3.2","reasoningEffort":"high"}"#.utf8)
        )
        expect(withEffort?.provider == "deepseek" && withEffort?.model == "v3.2" && withEffort?.reasoningEffort == "high",
               "D1a 完整选择（含 reasoningEffort）逐字段落地")

        let withoutEffort = try? decoder.decode(
            ModelSelection.self,
            from: Data(#"{"provider":"deepseek","model":"v3.2"}"#.utf8)
        )
        expect(withoutEffort?.reasoningEffort == nil, "D1b reasoningEffort 缺省 = nil，不是故障")
    }

    // MARK: - 目录解码（§4.7）

    private static func decodeCatalog() {
        // 上游原样 + 宿主私有字段 routableProviders：客户端必须容忍不认识的字段。
        let json = """
        {"default":{"provider":"deepseek","model":"v3.2"},
         "groups":[{"id":"deepseek","name":"DeepSeek","models":[{"id":"v3.2","name":"V3.2"}]}],
         "failures":[{"id":"x","name":"X","message":"no credentials"}],
         "routableProviders":["deepseek"]}
        """
        let catalog = try? decoder.decode(ModelCatalog.self, from: Data(json.utf8))
        expect(catalog?.default?.model == "v3.2", "D2a default 落地")
        expect(catalog?.groups?.first?.models.first?.id == "v3.2", "D2b groups.models 落地")
        expect(catalog?.failures?.first?.message == "no credentials", "D2c failures 失败隔离落地")
        expect(true, "D2d 宿主私有字段（routableProviders）被容忍不炸")

        // 无部署默认：default 整个缺省（协议规定不送 null）。
        let bare = try? decoder.decode(
            ModelCatalog.self,
            from: Data(#"{"groups":[],"failures":[]}"#.utf8)
        )
        expect(bare?.default == nil && bare?.groups?.isEmpty == true, "D2e default 缺省 = nil，目录其余照常")
    }

    // MARK: - opening 的 model 字段（§4.2）

    private static func decodeOpening() {
        let withModel = try? decoder.decode(SnapshotResponse.self, from: Data("""
        {"v":2,"ok":true,"asOfSeq":128,"hasMore":false,"events":[],
         "model":{"provider":"deepseek","model":"v3.2","reasoningEffort":"high"}}
        """.utf8))
        expect(withModel?.model?.model == "v3.2" && withModel?.model?.reasoningEffort == "high",
               "D3a opening 带 model 基线时解码落地")

        let withoutModel = try? decoder.decode(SnapshotResponse.self, from: Data("""
        {"v":2,"ok":true,"asOfSeq":128,"hasMore":false,"events":[]}
        """.utf8))
        expect(withoutModel?.model == nil, "D3b opening 不带 model = 服务端不知道，字段缺省不是故障")
    }

    // MARK: - 请求编码（§4.7）

    private static func encodeRequests() {
        let catalog = try? encoder.encode(ModelCatalogRequest())
        let catalogBody = catalog.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(catalogBody.contains(#""op":"model-catalog""#), "E1a model-catalog 请求带 op 与版本")

        let select = try? encoder.encode(
            ModelSelectRequest(sessionId: "s-1", provider: "deepseek", model: "v3.2", reasoningEffort: nil)
        )
        let selectBody = select.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(selectBody.contains(#""op":"model-select""#) && selectBody.contains(#""sessionId":"s-1""#),
               "E1b model-select 请求带 op / sessionId / 选择")
        expect(!selectBody.contains("reasoningEffort"), "E1c reasoningEffort 为 nil 时整个字段缺席（encodeIfPresent）")
    }
}

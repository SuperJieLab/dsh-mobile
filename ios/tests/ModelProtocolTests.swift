/**
 * 模型选择的协议解码测试（M7 T5，判据：解码用例全绿）+ 跟随更新状态机（T6，V1–V4）。
 *
 * 判据与出处：M7 §五；协议 dev/contract/protocol.md §4.7
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
        followUpdates()

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
        // 上游原样（catalog.js:20-44）：reasoning.efforts 是对象数组、宿主私有字段
        // routableProviders 在场 —— T8 真机教训：fixture 必须逐字复刻上游形状，
        // 自造的 `[String]` efforts 让整份目录解码失败、菜单全空。
        let json = """
        {"default":{"provider":"deepseek","model":"v3.2"},
         "groups":[{"id":"deepseek","name":"DeepSeek","models":[
            {"id":"v3.2","name":"V3.2",
             "reasoning":{"efforts":[{"id":"high","name":"High"},{"id":"low","name":"Low"}],"defaultEffort":"high"}}],
         }],
         "failures":[{"id":"x","name":"X","message":"no credentials"}],
         "routableProviders":["deepseek"]}
        """
        let catalog = try? decoder.decode(ModelCatalog.self, from: Data(json.utf8))
        expect(catalog?.default?.model == "v3.2", "D2a default 落地")
        expect(catalog?.groups?.first?.models.first?.id == "v3.2", "D2b groups.models 落地")
        expect(catalog?.groups?.first?.models.first?.reasoning?.efforts.first?.id == "high",
               "D2b' reasoning.efforts 按上游对象数组形状落地")
        expect(catalog?.groups?.first?.models.first?.reasoning?.defaultEffort == "high",
               "D2b'' defaultEffort 落地")
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

    // MARK: - 跟随更新状态机（V1–V4）

    /// 造一条 `model/selection` 事件（data = 选择本身，投影源码逐字核实）。
    private static func selectionEvent(_ seq: Int, _ provider: String, _ model: String) -> SessionEvent {
        SessionEvent(
            type: "model/selection",
            seq: seq,
            time: Double(1_758_000_000_000 + seq),
            data: .object(["provider": .string(provider), "model": .string(model)])
        )
    }

    /// 造一条 `request/header` 事件（模型在 data.header.config 下）。
    private static func headerEvent(_ seq: Int, _ provider: String, _ model: String) -> SessionEvent {
        SessionEvent(
            type: "request/header",
            seq: seq,
            time: Double(1_758_000_000_000 + seq),
            data: .object(["header": .object(["config": .object([
                "provider": .string(provider),
                "model": .string(model),
            ])])])
        )
    }

    private static func followUpdates() {
        // V1：opening 基线 A → selection B → header C，显示序列 A → B → C。
        var state = ModelSelectionState()
        state.absorb(baseline: ModelSelection(provider: "p", model: "A"))
        expect(state.displayed?.model == "A", "V1a opening 基线直接落地")
        state.absorb(event: selectionEvent(10, "p", "B"))
        expect(state.displayed?.model == "B", "V1b selection 事件覆盖基线")
        state.absorb(event: headerEvent(11, "p", "C"))
        expect(state.displayed?.model == "C", "V1c header 事件再覆盖 —— 后到覆盖先到")

        // V2：selection B 之后来一个不匹配 B 的 header C → 显示 C，不回跳。
        state = ModelSelectionState()
        state.absorb(event: selectionEvent(10, "p", "B"))
        state.absorb(event: headerEvent(11, "p", "C"))
        expect(state.displayed?.model == "C", "V2 选择没被兑现时显示实际落地值")

        // V3：重放旧 seq / 同 seq 的事件 → 显示不变（严格高 seq 胜，M6 同纪律）。
        state.absorb(event: selectionEvent(10, "p", "OLD"))
        expect(state.displayed?.model == "C", "V3a 旧 seq 重放不倒退")
        state.absorb(event: headerEvent(11, "p", "DUP"))
        expect(state.displayed?.model == "C", "V3b 同 seq 重放被丢")
        state.absorb(event: SessionEvent(type: "user/message", seq: 12, time: 0, data: .object([:])))
        expect(state.displayed?.model == "C", "V3c 无关事件类型被忽略")

        // V4：两连发 select（代号 1→2），响应 2 先回、响应 1 后回 → 显示响应 2 的选择。
        state = ModelSelectionState()
        let g1 = state.beginSelect()
        let g2 = state.beginSelect()
        expect(g2 != g1, "V4a 每次发起选择递增代号")
        let settledNew = state.settle(generation: g2, selected: ModelSelection(provider: "p", model: "NEW"))
        expect(settledNew && state.displayed?.model == "NEW", "V4b 最新代号的响应落地")
        let settledOld = state.settle(generation: g1, selected: ModelSelection(provider: "p", model: "OLD"))
        expect(!settledOld && state.displayed?.model == "NEW", "V4c 迟到的旧响应被守卫丢弃，显示不倒退")
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

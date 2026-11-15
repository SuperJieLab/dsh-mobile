/**
 * TransientChannel 的契约测试（TC1–TC8）：状态机不碰网络 / UI / 持久化。
 * revision 语义照上游：**每帧全局 +1**，start/chunk/end 都占号；
 * `index` 是 attempt 内 chunk 位置，start 后从 0 起。断号即 broken，重开流取新基线。
 *
 * 通道的产物是**带小数序号的事件**（交给组装引擎），不再累积一段字符串 ——
 * 所以断言看的是事件的 `order` 与 `chunk`，不再有 `channel.text`。
 */
import Foundation
import XCTest

@testable import DshMobile

final class TransientChannelTests: XCTestCase {

    // MARK: - JSON 便捷构造

    private func object(_ pairs: (String, JSONValue)...) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }

    private func start(_ revision: Int, turn: Int = 1, step: Int = 1) -> JSONValue {
        object(
            ("type", .string("start")),
            ("attemptId", .string("a1")),
            ("revision", .number(Double(revision))),
            ("turn", .number(Double(turn))),
            ("step", .number(Double(step)))
        )
    }

    private func chunk(_ index: Int, revision: Int, text: String) -> JSONValue {
        object(
            ("type", .string("chunk")),
            ("attemptId", .string("a1")),
            ("revision", .number(Double(revision))),
            ("index", .number(Double(index))),
            ("time", .number(1_700_000_000_000)),
            ("chunk", object(("type", .string("text-delta")), ("index", .number(0)), ("text", .string(text))))
        )
    }

    private func end(_ revision: Int, chunks: Int, outcome: JSONValue? = nil) -> JSONValue {
        object(
            ("type", .string("end")),
            ("attemptId", .string("a1")),
            ("revision", .number(Double(revision))),
            ("index", .number(Double(chunks))),
            ("outcome", outcome ?? object(("kind", .string("abandoned"))))
        )
    }

    /// 开场基线：已用掉 `usedRevision` 号；attempt 内已累积 `stream` 段，
    /// 下一个 chunk 位置是 `nextIndex`。
    ///
    /// `stream` 走**真实紧凑形状**（`text-chunks` 记录 + `dt` 间隔），不是一条记录一个 chunk ——
    /// 后者线上不存在，按它写夹具会把「根本没展开」这类错测成绿。
    private func baseline(usedRevision: Int, nextIndex: Int, stream: [String], turn: Int = 1, step: Int = 1) -> JSONValue {
        let gaps = Array(repeating: 10.0, count: max(0, stream.count - 1))
        return object(
            ("revision", .number(Double(usedRevision))),
            ("activeAttempt", object(
                ("attemptId", .string("a1")),
                ("turn", .number(Double(turn))),
                ("step", .number(Double(step))),
                ("nextIndex", .number(Double(nextIndex))),
                ("stream", .array([
                    object(("type", .string("text-chunks")),
                           ("time0", .number(1_700_000_000_000)),
                           ("index", .number(0)),
                           ("dt", .array(gaps.map { .number($0) })),
                           ("texts", .array(stream.map { .string($0) })))
                ]))
            ))
        )
    }

    // MARK: - 结果判读

    /// 一帧消化掉的事件里的文本（按到达顺序拼起来）。
    private func text(_ result: TransientChannel.Result) -> String? {
        guard case .consumed(let events) = result else { return nil }
        return events.compactMap { $0.data["chunk"]?["text"]?.string }.joined()
    }

    private func events(_ result: TransientChannel.Result) -> [AssemblyEvent]? {
        guard case .consumed(let events) = result else { return nil }
        return events
    }

    // MARK: - 用例

    func testBaselineRestoresAccumulatedContent() {
        // TC1：基线里的内容变成事件交出去，位置落在游标之后；期望 revision = 已用号 + 1。
        var channel = TransientChannel()
        let restored = channel.apply(baseline: baseline(usedRevision: 3, nextIndex: 2, stream: ["你好", "，世界"]), cursor: 20)
        XCTAssertEqual(restored.count, 2, "TC1a 基线里的两段都要还原成事件")
        XCTAssertEqual(restored.compactMap { $0.data["chunk"]?["text"]?.string }.joined(), "你好，世界", "TC1b 紧凑流展开的顺序与内容")
        XCTAssertEqual(restored.compactMap { $0.time }, [1_700_000_000_000, 1_700_000_000_010], "TC1b2 展开要按 dt 还原时间")
        XCTAssertTrue(restored[0].order > 20 && restored[0].order < restored[1].order && restored[1].order < 21,
                      "TC1c 序号落在游标与它之后那条之间，且按到达顺序递增")
        XCTAssertTrue(channel.isLive, "TC1d 基线带进行中 attempt ⇒ isLive")

        // TC2：基线之后的第一帧 revision 必须 = 已用号 + 1，index 接着 nextIndex。
        let first = channel.apply(frame: chunk(2, revision: 4, text: "！"), cursor: 20)
        XCTAssertEqual(text(first), "！", "TC2 依序的 chunk 要交出一条事件")
        let second = channel.apply(frame: chunk(3, revision: 5, text: "欢迎"), cursor: 20)
        XCTAssertEqual(text(second), "欢迎", "TC2b 第二帧继续 +1/+1")
    }

    func testRevisionGapIsBroken() {
        // TC3：revision 跳号 ⇒ broken（基线已丢，干等只会残缺）。
        var channel = TransientChannel()
        _ = channel.apply(baseline: baseline(usedRevision: 3, nextIndex: 0, stream: []), cursor: 0)
        guard case .broken = channel.apply(frame: chunk(0, revision: 9, text: "跳"), cursor: 0) else {
            return XCTFail("TC3 revision 跳号应判 broken")
        }
    }

    func testIndexGapIsBroken() {
        // TC4：index 断号 ⇒ broken。
        var channel = TransientChannel()
        _ = channel.apply(baseline: baseline(usedRevision: 3, nextIndex: 5, stream: []), cursor: 0)
        guard case .broken = channel.apply(frame: chunk(7, revision: 4, text: "跳"), cursor: 0) else {
            return XCTFail("TC4 index 断号应判 broken")
        }
    }

    func testStartChunkEndCarriesTheNamedSettlement() {
        // TC5：start → chunk → end（committed）。`end` 要交出点名所需的 seq。
        var channel = TransientChannel()
        _ = channel.apply(baseline: baseline(usedRevision: 0, nextIndex: 0, stream: []), cursor: 0)
        guard case .consumed(let opened) = channel.apply(frame: start(1), cursor: 0) else {
            return XCTFail("TC5a start 应被消化")
        }
        XCTAssertTrue(opened.isEmpty, "TC5b start 本身不带内容")
        XCTAssertTrue(channel.isLive)

        _ = channel.apply(frame: chunk(0, revision: 2, text: "正在生成"), cursor: 0)
        let settled = end(3, chunks: 1, outcome: object(("kind", .string("committed")),
                                                       ("eventType", .string("assistant/message")),
                                                       ("seq", .number(42))))
        guard case .ended(let settlement) = channel.apply(frame: settled, cursor: 0) else {
            return XCTFail("TC5c end 应交出结算")
        }
        XCTAssertEqual(settlement.seq, 42, "TC5d 点名用的是 end 帧的 outcome.seq")
        XCTAssertEqual(settlement.eventType, "assistant/message")
        XCTAssertFalse(channel.isLive, "TC5e end 之后不再有进行中的 attempt")
    }

    func testAbandonedEndsWithoutNaming() {
        // TC5f：被放弃的一轮没有定稿事件可认 —— 交空 seq，让上层把草稿整批撤掉。
        var channel = TransientChannel()
        _ = channel.apply(baseline: baseline(usedRevision: 0, nextIndex: 0, stream: []), cursor: 0)
        _ = channel.apply(frame: start(1), cursor: 0)
        guard case .ended(let settlement) = channel.apply(frame: end(2, chunks: 0), cursor: 0) else {
            return XCTFail("TC5f 放弃也要交出结算")
        }
        XCTAssertNil(settlement.seq)
    }

    func testNonTextChunkStillAdvancesSequence() {
        // TC6：非文本 chunk 照样占 revision/index —— 它也要交给引擎（思考、工具参数都在里面）。
        var channel = TransientChannel()
        _ = channel.apply(baseline: baseline(usedRevision: 10, nextIndex: 0, stream: []), cursor: 0)
        _ = channel.apply(frame: start(11), cursor: 0)
        let reasoning = object(
            ("type", .string("chunk")),
            ("revision", .number(12)),
            ("index", .number(0)),
            ("chunk", object(("type", .string("reasoning-delta")), ("index", .number(0)), ("text", .string("思考"))))
        )
        guard case .consumed(let first) = channel.apply(frame: reasoning, cursor: 7) else {
            return XCTFail("TC6a 思考帧应被消化")
        }
        XCTAssertEqual(first.first?.data["chunk"]?["type"]?.string, "reasoning-delta")
        XCTAssertEqual(text(channel.apply(frame: chunk(1, revision: 13, text: "正文"), cursor: 7)), "正文",
                       "TC6b 非文本帧之后序号照常推进")
    }

    func testIdleBaselineLeavesACleanChannel() {
        // TC7：没有进行中 attempt 的基线 ⇒ 干净的空通道（但 revision 水位已对齐）。
        var idle = TransientChannel()
        _ = idle.apply(frame: chunk(0, revision: 1, text: "残留"), cursor: 0)
        let restored = idle.apply(baseline: object(("revision", .number(5))), cursor: 0)
        XCTAssertTrue(restored.isEmpty && !idle.isLive, "TC7a 无 attempt 基线清空一切")
        guard case .consumed = idle.apply(frame: start(6), cursor: 0) else {
            return XCTFail("TC7b 基线后的 start 用 revision+1")
        }
    }

    func testSecondAttemptResetsIndex() {
        // TC8：多 attempt —— 第二个 attempt 的 start 之后 index 重置、revision 继续。
        var channel = TransientChannel()
        _ = channel.apply(baseline: baseline(usedRevision: 0, nextIndex: 0, stream: []), cursor: 0)
        _ = channel.apply(frame: start(1), cursor: 0)
        _ = channel.apply(frame: chunk(0, revision: 2, text: "第一轮"), cursor: 0)
        _ = channel.apply(frame: end(3, chunks: 1), cursor: 0)
        guard case .consumed = channel.apply(frame: start(4), cursor: 0) else {
            return XCTFail("TC8a 第二轮 start 应被消化")
        }
        XCTAssertEqual(text(channel.apply(frame: chunk(0, revision: 5, text: "第二轮"), cursor: 0)), "第二轮",
                       "TC8b 新 attempt 的 index 从 0 重来")
    }
}

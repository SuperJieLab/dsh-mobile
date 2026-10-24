/**
 * 装配的判据：`LongConnection` 把两个模板真的接上了没有。
 *
 * 这一组刻意**不用替身接替装配**：它是唯一能证明「接上了」的地方。别处（`StreamMuxTests`）
 * 用假 `Channel` 验流层的反应，用 `WebSocketConnectionTests` 验连接层自己的编排 ——
 * 两边的判据都绿而装配漏一行，是这一层最容易出的错，也是唯一两边都看不见的那一格。
 *
 * 用真的 `WebSocketConnection` + 连不上的端点（`127.0.0.1:1`），与 `WebSocketConnectionTests`
 * 同一手法：握手会真发起（必定失败），但**阶段与编号的变化是同步的**，断言紧跟在动作之后。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class LongConnectionTests: XCTestCase {

    /// 一个只记事的判读：造流时给一段能编出来的开流文本。
    private final class Behavior: StreamBehavior {
        let label = "witness"
        func build(_ id: StreamId) throws -> String {
            #"{"type":"open","streamId":"\#(id)"}"#
        }
        func handle(_ envelope: MuxServerEnvelope, raw: Data) -> StreamReply { StreamReply() }
    }

    /// 装配好的长连接。四个能力都给了真值 —— 只给 nil 会让「漏接」与「没接」同形。
    ///
    /// 端点指向连不上的 `127.0.0.1:1`：握手失败走退避，这一组只断言同步可观察的那几格。
    private func link() -> LongConnection {
        LongConnection(
            authorization: { "ticket" },
            renewTicket: { .unavailable },
            session: { .shared },
            baseURL: { URL(string: "http://127.0.0.1:1")! }
        )
    }

    /// 一激活就进「握手中」—— 这一格同时守住三处接线。
    ///
    /// 三个漏接各有各的错法，而它们都能被这一个断言抓到：
    /// - 漏 `onPhaseChange`：阶段永远停在 `.idle`，网络格不动；
    /// - 漏 `baseURL`：默认闭包回 `nil`，`connect` 直接进退避 ⇒ 阶段是 `.waiting`；
    /// - 漏 `authorization`：升级时没有票 ⇒ 先去换票（换不到）⇒ 阶段退回 `.idle`。
    ///
    /// 装配能漏掉的行远不止这三处，抓不到的写在下面：`session` 与 `renewTicket` 漏接之后
    /// 行为与接上时无法区分（默认传输是 `.shared`、换票只在真需要时才发生），
    /// `onFrame` 漏接的后果要等真有一帧才显现 —— 那两条靠代码评审，不假装这里验过。
    func testActivatingEntersTheHandshake() {
        let link = link()
        XCTAssertEqual(link.phase, .idle, "还没要连接")

        link.activate()
        XCTAssertEqual(link.phase, .connecting, "接了三条线才进得了握手")

        link.activate()
        XCTAssertEqual(link.phase, .connecting, "重复激活不叠加")
    }

    /// 换代次真的走到了流表：开出去过的流换号 —— 这是「两个模板接上了」的端到端证据。
    ///
    /// 断的是**编号变了**这件事，不是「事件被发出去了」。差别是关键：发出事件而没人订阅时，
    /// 一个数调用次数的结构断言照样绿，而流永远用旧号重开（服务端按号归流，旧号早作废了）。
    ///
    /// 为什么要等一轮退避：流必须**先开出去过**才谈得上换号 —— 首次开流用当时的号，
    /// 换代次才重开。于是这一条走真路径：激活 → 造流（这一代有连接，open 当场发出）→
    /// 握手失败 → 退避到点重连 → 换代次 → 换号。等的是状态，不是固定时长。
    ///
    /// ⚠️ 这一条会真的发起握手（端点连不上，必定失败），与 `WebSocketConnectionTests` 同性质。
    func testGenerationChangeReachesTheStreamTable() async throws {
        let link = link()
        link.activate()
        let stream = try XCTUnwrap(link.makeStream(Behavior()))
        let firstId = stream.id

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && stream.id == firstId {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotEqual(stream.id, firstId, "装配通了才换得了号")
        // 不留收尾：统筹层不对外提供「不要连接了」（连接常驻），这一代的退避循环会活到
        // 进程结束。它只写日志、不再改编号，断言已在上面同步完成。
    }

    /// 造流口归统筹层转发，屏幕那一侧拿到的是它而不是连接本体。
    ///
    /// 守的是「造流只有一条路」：`makeStream` 是 `StreamFactory` 的唯一成员，
    /// 返回 `nil` 意味着开流文本编不出来 —— 那条流相当于没造出来，调用方要能分辨。
    func testMakingAStreamGoesThroughTheOneFactory() throws {
        let link = link()
        let stream = try XCTUnwrap(link.makeStream(Behavior()))
        XCTAssertEqual(stream.label, "witness", "标签来自注入的判读")
    }
}

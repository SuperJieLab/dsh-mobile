/**
 * 两端共守的 mux 帧样本 —— 这里读的是**同一份文件**，不是各写一份字面量。
 *
 * 网关那条在 `gateway/tests/wire/mux-fixture.test.ts`。两边各写自己的样本时，
 * 改一端而另一端没跟上，两边的测试都还绿 —— 只有联调或真机才暴露。
 *
 * 两个方向各有一条判据：
 * - client 段：这里编出这些字节（逐字比较），网关端必须把它们解成同一组语义；
 * - server 段：网关端编出这些字节，这里必须解得开。
 */
import Foundation
import XCTest

@testable import DshMobile

final class MuxFrameFixtureTests: XCTestCase {

    /// 共守样本随测试包一起分发：手机上读不到仓库路径，所以工程里以**资源引用**把它指进
    /// 测试包的 Resources 阶段（`project.pbxproj` 里 `path = "../contract/mux-frames.json"`）。
    /// 加一条样本不动工程文件 —— 投递的是整份文件，与条数无关。
    private static var fixtureURL: URL? {
        Bundle(for: MuxFrameFixtureTests.self).url(forResource: "mux-frames", withExtension: "json")
    }

    private struct ClientSample {
        let name: String
        let text: String
        let type: String
        let streamId: String
        let kind: String?
        let sessionId: String?
    }

    private struct ServerSample {
        let name: String
        let text: String
        let type: String
        let streamId: String
    }

    private func loadFixture() throws -> (client: [ClientSample], server: [ServerSample]) {
        guard let url = Self.fixtureURL else {
            XCTFail("测试包里没有 mux-frames.json —— 资源引用没进测试包")
            return ([], [])
        }
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let client = (root["client"] as? [[String: Any]] ?? []).compactMap { raw -> ClientSample? in
            guard let name = raw["name"] as? String,
                  let text = raw["text"] as? String,
                  let type = raw["type"] as? String,
                  let streamId = raw["streamId"] as? String else { return nil }
            return ClientSample(name: name, text: text, type: type, streamId: streamId,
                                kind: raw["kind"] as? String, sessionId: raw["sessionId"] as? String)
        }
        let server = (root["server"] as? [[String: Any]] ?? []).compactMap { raw -> ServerSample? in
            guard let name = raw["name"] as? String,
                  let text = raw["text"] as? String,
                  let type = raw["type"] as? String,
                  let streamId = raw["streamId"] as? String else { return nil }
            return ServerSample(name: name, text: text, type: type, streamId: streamId)
        }
        return (client, server)
    }

    /// 样本少一条时下面的循环会静默少测一格，而「少测一格」在测试报告里长得跟「全绿」一样。
    func testFixtureCoversEveryStreamKindAndBothServerFrameKinds() throws {
        let fixture = try loadFixture()
        let kinds = Set(fixture.client.compactMap(\.kind))
        XCTAssertEqual(kinds, Set(["follow", "events", "control"]),
                       "三条流的开流请求都要有样本")
        let serverTypes = Set(fixture.server.map(\.type))
        for type in ["item", "end", "error"] {
            XCTAssertTrue(serverTypes.contains(type), "服务端帧缺 \(type) 的样本")
        }
    }

    /// 货物级的覆盖：`item` 的 `type` 有三种是线上会发生、且我们要读的。
    /// 只数信封种类的话，删掉一条货物样本，上面那条判据照样全绿。
    func testFixtureCoversEveryServerCargo() throws {
        let fixture = try loadFixture()
        let names = Set(fixture.server.map(\.name))
        for required in ["item-events-ready", "item-events-emit", "item-events-question"] {
            XCTAssertTrue(names.contains(required), "server 段缺样本 \(required)")
        }
    }

    /// 手机端编出的字节必须**逐字**等于样本 —— 这一半是「网关要解的东西没变」。
    func testEveryClientSampleIsExactlyWhatThePhoneEncodes() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.client.isEmpty, "样本为空时下面的循环什么都不测")

        for sample in fixture.client {
            let encoded: String
            switch sample.type {
            case "open":
                switch sample.kind {
                case "follow":
                    let sessionId = try XCTUnwrap(sample.sessionId, "\(sample.name): follow 缺会话名")
                    encoded = try MuxOpenFrame.following(sessionId: sessionId, streamId: sample.streamId).encoded()
                case "events":
                    encoded = try MuxOpenFrame.events(streamId: sample.streamId).encoded()
                case "control":
                    encoded = try MuxOpenFrame.control(streamId: sample.streamId).encoded()
                default:
                    XCTFail("\(sample.name): 样本里的 kind 不认识（\(sample.kind ?? "nil")）")
                    continue
                }
            case "cancel":
                encoded = try MuxCancelFrame(streamId: sample.streamId).encoded()
            default:
                XCTFail("\(sample.name): 样本里的 type 不认识（\(sample.type)）")
                continue
            }
            XCTAssertEqual(encoded, sample.text,
                           "\(sample.name): 手机端编出的字节与共守样本不一致 —— 网关按样本解析")
        }
    }

    /// 网关编出的字节，手机端必须解得开 —— 这一半是「网关发的东西手机认」。
    ///
    /// **信封之外还要验载荷**：只验 `type` / `streamId` 的话，网关改一个字段、客户端解不开，
    /// 两边的判据都还绿。分派按 `value.type`，与生产解码器同一张表 —— 这里不另写一套判别。
    func testEveryServerSampleIsWhatThePhoneCanRead() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.server.isEmpty, "样本为空时下面的循环什么都不测")

        for sample in fixture.server {
            let data = try XCTUnwrap(sample.text.data(using: .utf8))
            let frame = try XCTUnwrap(InboundFrame.decode(data), "\(sample.name): 这一帧该解得开")
            XCTAssertEqual(frame.type, sample.type, "\(sample.name): 信封的 type")
            XCTAssertEqual(frame.streamId, sample.streamId, "\(sample.name): 编号")
            // `end` / `error` 没有 `item` 载荷 —— 跳过，不是失败。
            guard frame.type == "item" else { continue }
            let payload = try XCTUnwrap(frame.payload, "\(sample.name): item 帧该有载荷")
            guard case .item(let item) = payload else {
                XCTFail("\(sample.name): item 帧的载荷该是 .item")
                continue
            }
            assertCargo(item, sample: sample.name)
        }
    }

    /// 按货物支断言载荷 —— 每支只验客户端**真读**的那几格。
    ///
    /// `waterfall` 的载荷在客户端是裸 `JSONValue`（题目结构归第 3 期的问题卡解析），
    /// 所以这里验的是「地址三格与工具名读得出来」，不是题目内部的字段。
    /// `ready` 只验 `clientId` —— 客户端解不出 `host`（`EventsValue.ready` 里没有这一格），
    /// 样本带 `host` 要证明的是「多一格也解得出」，不是「读到了」。
    private func assertCargo(_ item: ItemPayload, sample: String) {
        switch item {
        case .events(.ready(let clientId)):
            XCTAssertEqual(clientId, "c-1", "\(sample): ready 的 clientId 该是样本里那个固定值")
        case .events(.waterfall(let value)):
            let event = value["event"]?.string ?? ""
            XCTAssertTrue(["approval/request", "user-questions/request"].contains(event),
                          "\(sample): waterfall 的 event 该是上游事件名（读出来是 \(event)）")
            XCTAssertNotNil(value["eventId"]?.string, "\(sample): eventId 可读")
            XCTAssertNotNil(value["agentId"]?.string, "\(sample): agentId 可读")
            if event == "user-questions/request" {
                // 题目内部的结构归第 3 期的问题卡解析：现在只证明这一格在，不验它的字段。
                XCTAssertNotNil(value["request"]?["questions"], "\(sample): request.questions 这一格在")
            } else {
                XCTAssertNotNil(value["request"]?["toolName"]?.string,
                                "\(sample): request.toolName 可读 —— 客户端按它建卡")
            }
        case .events(.emit(let event, let args)):
            XCTAssertEqual(event, "commands/change", "\(sample): emit 的 event")
            // `args` 缺省解成 `.null` —— 所以这条能抓「网关这一格空了」，而不是恒真。
            XCTAssertNotEqual(args, .null, "\(sample): emit 的 args 不该缺席")
        case .unknown:
            // 未知 `type` 也解得开（它落进 `.unknown`），所以 `XCTUnwrap` 那一步发现不了 ——
            // 「样本的货物与解码器对不上」只能在这里喊。
            XCTFail("\(sample): 货物落进了 .unknown —— 判别没认出来")
        case .events, .follow, .control:
            break
        }
    }

    /// `host` 是可选的：上游不给时那一格缺席（不是空串、不是 `{"home":""}`）。
    /// 样本里那一条带 `host`，这里补上不带的那一半 —— 缺席不等于解码失败。
    func testReadyWithoutHostStillDecodes() throws {
        let text = #"{"type":"item","streamId":"e-1","value":{"type":"ready","clientId":"c-1"}}"#
        let data = try XCTUnwrap(text.data(using: .utf8))
        let frame = try XCTUnwrap(InboundFrame.decode(data), "不带 host 的 ready 该解得开")
        guard case .item(.events(.ready(let clientId)))? = frame.payload else {
            XCTFail("不带 host 的 ready 该落在 .events(.ready)")
            return
        }
        XCTAssertEqual(clientId, "c-1")
    }
}

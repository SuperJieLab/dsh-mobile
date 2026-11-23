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
        /// 这条货物属于哪条流 —— 按流解码之后，「由谁解」必须写在样本里。
        let kind: String?
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
            return ServerSample(name: name, text: text, type: type, streamId: streamId,
                                kind: raw["kind"] as? String)
        }
        return (client, server)
    }

    /// 样本少一条时下面的循环会静默少测一格，而「少测一格」在测试报告里长得跟「全绿」一样。
    func testFixtureCoversEveryStreamKindAndBothServerFrameKinds() throws {
        let fixture = try loadFixture()
        let kinds = Set(fixture.client.compactMap(\.kind))
        XCTAssertEqual(kinds, Set(["follow", "events", "control", "workspace"]),
                       "四条流的开流请求都要有样本")
        let serverTypes = Set(fixture.server.map(\.type))
        for type in ["item", "end", "error"] {
            XCTAssertTrue(serverTypes.contains(type), "服务端帧缺 \(type) 的样本")
        }
        // 按流解码之后，`item` 样本必须写明属于哪条流 —— 否则客户端不知道该用哪张表解。
        let itemKinds = Set(fixture.server.filter { $0.type == "item" }.compactMap(\.kind))
        XCTAssertEqual(itemKinds, Set(["follow", "events", "workspace"]),
                       "item 样本的 kind 应覆盖三条会推货物的流")
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
            // `end` / `error` 没有货物 —— 跳过，不是失败。
            guard frame.type == "item" else { continue }
            let value = try XCTUnwrap(frame.value, "\(sample.name): item 帧该有货物原文")

            // 货物的解由样本自己说归哪条流 —— 客户端没有一张全局表可以问。
            switch sample.kind {
            case "follow":
                guard case .decoded(.opening(let shape)) = FollowItem.read(value) else {
                    XCTFail("\(sample.name): follow 的样本该解成 opening")
                    continue
                }
                let opening = try XCTUnwrap(shape.frame(), "\(sample.name): 五格齐全该成形")
                XCTAssertEqual(opening.cursor, 3, "\(sample.name): 打开窗口的 cursor（含端，原样）")
                XCTAssertEqual(opening.header.id, "s-1", "\(sample.name): 会话名在头部")
                XCTAssertEqual(opening.records.map(\.event.seq), [3],
                               "\(sample.name): 记录里是事件（`event` 那一格）")
                XCTAssertEqual(opening.projections.asOfSeq, 3, "\(sample.name): 投影基线随行")
            case "events":
                guard case .decoded(let item) = EventsItem.read(value) else {
                    XCTFail("\(sample.name): events 的样本该解成 events 货物")
                    continue
                }
                assertCargo(item, sample: sample.name)
            case "workspace":
                guard case .decoded(.baseline(let baseline)) = WorkspaceItem.read(value) else {
                    XCTFail("\(sample.name): workspace 的样本该解成 baseline")
                    continue
                }
                XCTAssertEqual(baseline.items.map(\.workspaceId), ["w-1"], "\(sample.name): 组清单")
                XCTAssertEqual(baseline.items.first?.sessionIds, ["s-1"], "\(sample.name): 成员表（归属的来源）")
                XCTAssertEqual(baseline.pinnedSessionIds, ["s-1"], "\(sample.name): 置顶集合")
            default:
                XCTFail("\(sample.name): item 样本缺 kind —— 不知道该由哪条流解")
            }
        }
    }

    /// 按货物支断言载荷 —— 每支只验客户端**真读**的那几格。
    ///
    /// `waterfall` 的载荷在客户端是裸 `JSONValue`（题目结构归第 3 期的问题卡解析），
    /// 所以这里验的是「地址三格与工具名读得出来」，不是题目内部的字段。
    /// `ready` 只验 `clientId` —— 客户端解不出 `host`（`EventsItem.ready` 里没有这一格），
    /// 样本带 `host` 要证明的是「多一格也解得出」，不是「读到了」。
    private func assertCargo(_ item: EventsItem, sample: String) {
        switch item {
        case .ready(let clientId):
            XCTAssertEqual(clientId, "c-1", "\(sample): ready 的 clientId 该是样本里那个固定值")
        case .waterfall(let value):
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
        case .emit(let event, let args):
            XCTAssertEqual(event, "commands/change", "\(sample): emit 的 event")
            // `args` 缺省解成 `.null` —— 所以这条能抓「网关这一格空了」，而不是恒真。
            XCTAssertNotEqual(args, .null, "\(sample): emit 的 args 不该缺席")
        case .cancel:
            XCTFail("\(sample): 样本里不该有撤回帧")
        }
    }

    /// `host` 是可选的：上游不给时那一格缺席（不是空串、不是 `{"home":""}`）。
    /// 样本里那一条带 `host`，这里补上不带的那一半 —— 缺席不等于解码失败。
    func testReadyWithoutHostStillDecodes() throws {
        let text = #"{"type":"item","streamId":"e-1","value":{"type":"ready","clientId":"c-1"}}"#
        let data = try XCTUnwrap(text.data(using: .utf8))
        let frame = try XCTUnwrap(InboundFrame.decode(data), "不带 host 的 ready 该解得开")
        let value = try XCTUnwrap(frame.value, "ready 该有货物原文")
        guard case .decoded(.ready(let clientId)) = EventsItem.read(value) else {
            XCTFail("不带 host 的 ready 该落在 events.ready")
            return
        }
        XCTAssertEqual(clientId, "c-1")
    }
}

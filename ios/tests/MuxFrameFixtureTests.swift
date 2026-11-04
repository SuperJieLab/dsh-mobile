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

    /// 仓库根下的那一份。路径由 `#filePath` 现算 —— 它指向本文件，
    /// 上三级就是仓库根（`ios/tests/<本文件>`）。
    private static let fixturePath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ios/tests
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("contract/mux-frames.json")
            .path
    }()

    private struct ClientSample {
        let name: String
        let text: String
        let type: String
        let streamId: String
        let op: String?
        let sessionId: String?
    }

    private struct ServerSample {
        let name: String
        let text: String
        let type: String
        let streamId: String
    }

    private func loadFixture() throws -> (client: [ClientSample], server: [ServerSample]) {
        let url = URL(fileURLWithPath: Self.fixturePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "找不到共守样本：\(url.path) —— 两端要读同一份，它必须留在仓库里")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let client = (root["client"] as? [[String: Any]] ?? []).compactMap { raw -> ClientSample? in
            guard let name = raw["name"] as? String,
                  let text = raw["text"] as? String,
                  let type = raw["type"] as? String,
                  let streamId = raw["streamId"] as? String else { return nil }
            return ClientSample(name: name, text: text, type: type, streamId: streamId,
                                op: raw["op"] as? String, sessionId: raw["sessionId"] as? String)
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
    func testFixtureCoversBothStreamKindsAndBothServerFrameKinds() throws {
        let fixture = try loadFixture()
        let ops = Set(fixture.client.compactMap(\.op))
        XCTAssertEqual(ops, Set(["events", "follow"]), "两种开流请求都要有样本")
        let serverTypes = Set(fixture.server.map(\.type))
        for type in ["item", "end", "error"] {
            XCTAssertTrue(serverTypes.contains(type), "服务端帧缺 \(type) 的样本")
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
                switch sample.op {
                case "follow":
                    let sessionId = try XCTUnwrap(sample.sessionId, "\(sample.name): follow 缺会话名")
                    encoded = try MuxOpenFrame.following(sessionId: sessionId, streamId: sample.streamId).encoded()
                case "events":
                    encoded = try MuxOpenFrame.events(streamId: sample.streamId).encoded()
                default:
                    XCTFail("\(sample.name): 样本里的 op 不认识（\(sample.op ?? "nil")）")
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
    func testEveryServerSampleIsWhatThePhoneCanRead() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.server.isEmpty, "样本为空时下面的循环什么都不测")

        let decoder = JSONDecoder()
        for sample in fixture.server {
            let data = try XCTUnwrap(sample.text.data(using: .utf8))
            let envelope = try decoder.decode(MuxServerEnvelope.self, from: data)
            XCTAssertEqual(envelope.type, sample.type, "\(sample.name): 信封的 type")
            XCTAssertEqual(envelope.streamId, sample.streamId, "\(sample.name): 编号")
        }
    }
}

/**
 * 功能条三格的显示值：网络格逐条 phase × 路径、占用格的空态与有值态、Tone 到颜色的映射。
 *
 * 这些值是纯算出来的 —— 不碰网络、不碰 UI，所以能在这里逐条钉死。
 * 网络格是本期唯一有分歧的地方：`.waiting` 必须写「重连中…」而不是保留「直连」，
 * 因为 32pt 的格里图标与颜色的面积都太小，异常只能靠文字传。
 *
 * 期望值一律手写：从实现推出来的期望等于没测。
 */
import Foundation
import SwiftUI
import XCTest

@testable import DshMobile

final class ComposerStripTests: XCTestCase {

    /// 四条 `phase` × 三条路径 = 十二条，列全表。手写枚举追不上组合数 ——
    /// 少列一条，那种组合就永远没人管。
    func testNetworkCellForEveryShape() {
        let cases: [(FollowClient.Phase, CarrierPath?, String, String, ComposerStripModel.Tone)] = [
            (.idle, .direct, "连接中…", "arrow.triangle.2.circlepath", .normal),
            (.idle, .relay, "连接中…", "arrow.triangle.2.circlepath", .normal),
            (.idle, nil, "连接中…", "arrow.triangle.2.circlepath", .normal),
            (.connecting, .direct, "连接中…", "arrow.triangle.2.circlepath", .normal),
            (.connecting, .relay, "连接中…", "arrow.triangle.2.circlepath", .normal),
            (.connecting, nil, "连接中…", "arrow.triangle.2.circlepath", .normal),
            (.ready, .direct, "直连", "arrow.left.arrow.right", .normal),
            (.ready, .relay, "经中继", "personalhotspot", .attention),
            (.ready, nil, "已连接", "checkmark.circle", .normal),
            (.waiting(ms: 3_000), .direct, "重连中…", "wifi.slash", .attention),
            (.waiting(ms: 3_000), .relay, "重连中…", "wifi.slash", .attention),
            (.waiting(ms: 3_000), nil, "重连中…", "wifi.slash", .attention),
        ]
        for (phase, carrier, text, icon, tone) in cases {
            let cell = ComposerStripModel
                .make(phase: phase, carrier: carrier, usage: nil, modelName: "m").network
            let label = "phase=\(String(describing: phase)) carrier=\(String(describing: carrier))"
            XCTAssertEqual(cell.text, text, label)
            XCTAssertEqual(cell.systemImage, icon, label)
            XCTAssertEqual(cell.tone, tone, label)
        }
    }

    /// 颜色映射单独断言：上面十二条全绿时，把 `.attention` 改成绿色也发现不了。
    func testToneMapsToColour() {
        XCTAssertEqual(ComposerStrip.tint(.attention), Color.orange)
        XCTAssertEqual(ComposerStrip.tint(.normal), Color.secondary)
    }

    /// 没有读数时占位，不消失 —— 消失会让模型格横向挪一次，进屏头几百毫秒抖一下。
    func testUsageCellKeepsPlaceWhenEmpty() {
        let empty = ComposerStripModel.make(phase: .ready, carrier: .direct,
                                           usage: nil, modelName: "m")
        XCTAssertEqual(empty.usageText, "--")
        XCTAssertTrue(empty.usageIsEmpty)
    }

    /// 有读数时给出百分比，且不再标成空态。
    func testUsageCellForReading() {
        let usage = UsagePayload(usedTokens: 150_000, contextWindow: 1_000_000)
        let cell = ComposerStripModel.make(phase: .ready, carrier: .direct,
                                           usage: usage, modelName: "m")
        XCTAssertEqual(cell.usageText, "15%")
        XCTAssertFalse(cell.usageIsEmpty)
    }

    /// 模型格带等级时是「模型名 · 等级名」；没有等级时只剩模型名（不带分隔符、不留空档）。
    /// 期望值手写：从 `modelLabel` 反推期望等于没测。
    func testModelCellShowsLevelOnlyWhenKnown() {
        let withLevel = ComposerStripModel.make(phase: .ready, carrier: .direct,
                                                usage: nil, modelName: "deepseek-v3.2", effortName: "高")
        XCTAssertEqual(withLevel.modelLabel, "deepseek-v3.2 · 高")

        let withoutLevel = ComposerStripModel.make(phase: .ready, carrier: .direct,
                                                   usage: nil, modelName: "deepseek-v3.2")
        XCTAssertEqual(withoutLevel.modelLabel, "deepseek-v3.2", "没有等级时不该留下分隔符")
    }
}

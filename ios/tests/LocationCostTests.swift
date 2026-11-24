/**
 * 位置索引的增量代价 —— 前插时只重算「插入段 + 污染区间」。
 *
 * 两条判据分工：计数只证明「扫得少」，对拍只证明「扫得对」。少一条都会出假绿 ——
 * 只对拍会漏「整份重算也照样对」，只计数会漏「扫得少但扫错了」。
 */
import XCTest

@testable import DshMobile

final class LocationCostTests: XCTestCase {

    private func event(
        _ order: Int, _ type: String, turn: Int? = nil, step: Int? = nil
    ) -> AssemblyEvent {
        var fields: [String] = []
        if let turn { fields.append("\"turn\":\(turn)") }
        if let step { fields.append("\"step\":\(step)") }
        let data = try! JSONDecoder().decode(
            JSONValue.self, from: Data(("{" + fields.joined(separator: ",") + "}").utf8))
        return AssemblyEvent(order: Double(order), seq: order, type: type,
                             time: Double(order), data: data)
    }

    /// 一轮 = 5 条事件。order 与 turn 同序 —— 否则会触发引擎的「非单调匹配」不变量。
    private func turn(_ number: Int, startingAt base: Int) -> [AssemblyEvent] {
        [
            event(base, "turn/start", turn: number),
            event(base + 1, "step/start", turn: number, step: 1),
            event(base + 2, "user/message", turn: number, step: 1),
            event(base + 3, "step/end", turn: number, step: 1),
            event(base + 4, "turn/end", turn: number),
        ]
    }

    private func turns(_ range: ClosedRange<Int>) -> [AssemblyEvent] {
        range.flatMap { turn($0, startingAt: $0 * 10) }
    }

    /// 打开窗口、再前插一段更早的：两段扫描与整份重建给出逐条相同的坐标。
    ///
    /// 顺序就是真实顺序 —— 窗口先被扫过（坐标已存在），前插只补插入段（区间为空，
    /// 因为窗口首条是 `turn/start`，它自己重置扫描状态）。
    func testInsertingEarlierTurnsMatchesAFullRebuild() {
        let earlier = turns(1...10)
        let window = turns(11...20)

        var full = LocationIndex()
        full.rebuild(earlier + window)

        var split = LocationIndex()
        _ = split.advance(window, from: .initial)
        _ = split.advance(earlier, from: .initial)

        for e in earlier + window {
            XCTAssertEqual(split.locationOf(e), full.locationOf(e),
                           "\(e.type)@\(e.order) 的增量坐标与整份重建不同")
        }
    }

    /// 区间非空：窗口首条是一条不带 turn 的消息，它继承「插入段末尾的状态」——
    /// 前插之前是会话级，前插之后落进上一轮。这是本期唯一会真正改写既有坐标的形状。
    func testAnInheritingHeadIsRecomputedAfterPrepend() {
        let earlier = turns(1...10).dropLast()      // 去掉 turn 10 的 turn/end ⇒ 末尾停在 turn 10
        let head = [event(105, "user/message")]     // 不带 turn，靠继承
        let window = turns(11...20)

        var full = LocationIndex()
        full.rebuild(Array(earlier) + head + window)

        var split = LocationIndex()
        _ = split.advance(head + window, from: .initial)     // 打开时：head 是会话级
        var state = split.advance(Array(earlier), from: .initial)
        XCTAssertEqual(state.turn, 10, "插入段末尾该停在 turn 10")
        _ = split.advance(head, from: state)                 // 污染区间：只有 head 这一条

        for e in Array(earlier) + head + window {
            XCTAssertEqual(split.locationOf(e), full.locationOf(e),
                           "\(e.type)@\(e.order) 的继承坐标与整份重建不同")
        }
    }

    /// 只扫插入段与污染区间，且代价与历史长度无关。
    func testOnlyTheInsertedSegmentAndTheSpoiledRangeAreScanned() {
        func scanned(windowStartsAt: Int) -> Int {
            var index = LocationIndex()
            _ = index.advance(turns(windowStartsAt...(windowStartsAt + 100)), from: .initial)
            let before = index.scannedCount
            _ = index.advance(turns(1...10), from: .initial)     // 插入段 50 条，区间为空
            return index.scannedCount - before
        }

        let short = scanned(windowStartsAt: 20)
        let long = scanned(windowStartsAt: 300)
        XCTAssertEqual(short, 50, "插入段 50 条、区间为空，只该扫这 50 条")
        XCTAssertEqual(long, short, "扫的条数与历史长度无关")
    }
}

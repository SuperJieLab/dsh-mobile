/**
 * SessionMirror 的契约测试（SM1–SM14）：状态机不碰网络 / UI / 持久化，每条断言由状态机自决。
 * 跑法 = `xcodebuild test`（unit test target）；出处：M1 §5.1。
 */
import Foundation
import XCTest

@testable import DshMobile

final class SessionMirrorTests: XCTestCase {

  /** 一条事件：`seq` 参与判定，其余字段原样带着。 */
  private func event(_ seq: Int) -> SessionEvent {
    SessionEvent(
      type: "user/message",
      seq: seq,
      time: 1_758_000_000_000 + Double(seq),
      data: .object(["body": .string("#\(seq)")])
    )
  }

  /** 一段往回读的窗口。 */
  private func window(_ pageStart: Int, _ asOfSeq: Int, _ events: [SessionEvent], hasOlder: Bool = false) -> Window {
    Window(pageStart: pageStart, asOfSeq: asOfSeq, hasOlder: hasOlder, events: events)
  }

  private func snapshot(_ asOfSeq: Int, _ events: [SessionEvent], hasMore: Bool = false) -> Outcome {
    .received(Snapshot(asOfSeq: asOfSeq, hasMore: hasMore, events: events))
  }

  func testContract() {
    // MARK: SM1 首次合并

    // 分两批拉，覆盖「分块推进」：第一批 hasMore 为真。
    var mirror = SessionMirror()
    XCTAssertTrue(mirror.beginRequest(), "SM1 首次请求可以发起")
    let firstBatch = mirror.apply(snapshot(2, [event(0), event(1)], hasMore: true))
    XCTAssertTrue(firstBatch == .merged(added: 2), "SM1 第一批记为 2 条新增")
    XCTAssertTrue(mirror.cursor == 2, "SM1 游标落在本批末尾（不是整个日志的末尾）")

    XCTAssertTrue(mirror.beginRequest(), "SM1 第二批可以接着发起")
    let secondBatch = mirror.apply(snapshot(3, [event(2)]))
    XCTAssertTrue(secondBatch == .merged(added: 1), "SM1 第二批记为 1 条新增")
    XCTAssertTrue(mirror.events.count == 3, "SM1 两批合起来事件全收")
    XCTAssertTrue(mirror.cursor == 3, "SM1 游标等于服务端给的 asOfSeq")

    // MARK: SM2 空增量

    let viewBefore = mirror.events
    XCTAssertTrue(mirror.beginRequest(), "SM2 可以发起")
    let verdictCaughtUp = mirror.apply(snapshot(3, []))
    XCTAssertTrue(verdictCaughtUp == .caughtUp, "SM2 判定为已追平")
    XCTAssertTrue(mirror.events == viewBefore, "SM2 视图逐字节不变")
    XCTAssertTrue(mirror.cursor == 3, "SM2 游标不变")

    // MARK: SM3 缺口

    XCTAssertTrue(mirror.beginRequest(), "SM3 可以发起")
    let verdictGap = mirror.apply(snapshot(5, [event(4)]))
    XCTAssertTrue(verdictGap == .resetRequired(.gap), "SM3 首批 seq 跳过了游标 ⇒ 判定存在缺口")
    XCTAssertTrue(mirror.cursor == 3, "SM3 判定不等于自动重置：游标在调用方重置前不动")

    // MARK: SM4 幂等

    // 整批重复投递：首批的 seq 小于游标。这里不能判成缺口 —— 它已经在视图里了。
    var idempotent = SessionMirror()
    _ = idempotent.beginRequest()
    _ = idempotent.apply(snapshot(3, [event(0), event(1), event(2)]))
    let beforeRepeat = idempotent.events

    _ = idempotent.beginRequest()
    let repeated = idempotent.apply(snapshot(3, [event(0), event(1), event(2)]))
    XCTAssertTrue(repeated == .caughtUp, "SM4 整批重复投递不产生新增")
    XCTAssertTrue(idempotent.events == beforeRepeat, "SM4 事件不重复")
    XCTAssertTrue(idempotent.events.count == 3, "SM4 视图仍是 3 条")

    // 部分重叠：前半重复、后半是新的 —— 重复的丢掉，新的照收。
    _ = idempotent.beginRequest()
    let overlap = idempotent.apply(snapshot(5, [event(2), event(3), event(4)]))
    XCTAssertTrue(overlap == .merged(added: 2), "SM4 部分重叠时只算新增的两条")
    XCTAssertTrue(idempotent.events.count == 5, "SM4 重叠部分没有被写第二遍")
    XCTAssertTrue(idempotent.events.map(\.seq) == [0, 1, 2, 3, 4], "SM4 视图按 seq 连续")

    // MARK: SM5 水位倒退

    let cursorBefore = idempotent.cursor
    _ = idempotent.beginRequest()
    let wentBack = idempotent.apply(snapshot(cursorBefore - 1, []))
    XCTAssertTrue(wentBack == .resetRequired(.waterMarkWentBack), "SM5 asOfSeq 小于游标 ⇒ 判定水位倒退")
    XCTAssertTrue(idempotent.cursor == cursorBefore, "SM5 判定本身不动游标")

    // MARK: SM6 游标作废

    _ = idempotent.beginRequest()
    let voided = idempotent.apply(.refused(Refusal(code: "resync-required", message: "since cannot exist")))
    XCTAssertTrue(voided == .resetRequired(.cursorVoid), "SM6 resync-required ⇒ 判定游标作废")
    idempotent.reset()
    XCTAssertTrue(idempotent.cursor == 0 && idempotent.events.isEmpty, "SM6 重置后丢弃游标与视图，以 0 重来")

    // 其它错误码只是拒绝，不要求重置。
    _ = idempotent.beginRequest()
    let other = idempotent.apply(.refused(Refusal(code: "unknown-session", message: "no such session")))
    XCTAssertTrue(other == .refused(code: "unknown-session"), "SM6 其它错误码只作拒绝")

    // MARK: SM7 投递失败

    var fragile = SessionMirror()
    _ = fragile.beginRequest()
    _ = fragile.apply(snapshot(3, [event(0), event(1), event(2)]))
    let intactEvents = fragile.events
    let intactCursor = fragile.cursor

    _ = fragile.beginRequest()
    let incomplete = fragile.apply(.transportFailed)
    XCTAssertTrue(incomplete == .failed, "SM7 传输失败判定为失败")
    XCTAssertTrue(fragile.events == intactEvents, "SM7 视图不含半截数据")
    XCTAssertTrue(fragile.cursor == intactCursor, "SM7 游标不动")

    // MARK: SM8 单飞

    var single = SessionMirror()
    XCTAssertTrue(single.beginRequest(), "SM8 第一次发起成功")
    XCTAssertTrue(!single.beginRequest(), "SM8 在途时第二次发起被拒绝")
    _ = single.apply(snapshot(1, [event(0)]))
    XCTAssertTrue(single.beginRequest(), "SM8 响应返回后可以再次发起")

    // 在途时再发起被拒，也不得产生第二次合并 —— 用「被拒的请求没有响应可合并」体现。
    XCTAssertTrue(single.events.count == 1, "SM8 被拒的那次没有改动视图")

    // MARK: SM9 打开会话：窗口替换整个视图，之后接着追新增

    var opened = SessionMirror()
    XCTAssertTrue(opened.isEmpty, "SM9 新镜像里什么都没有")
    let verdictOpen = opened.open(with: window(1, 4, [event(1), event(2), event(3)], hasOlder: true))
    XCTAssertTrue(verdictOpen == .merged(added: 3), "SM9 打开会话合并了整段窗口")
    XCTAssertTrue(opened.pageStart == 1 && opened.hasOlder, "SM9 窗口起点与「还有更早的」都记下了")
    XCTAssertTrue(opened.cursor == 4, "SM9 位置落在窗口末尾，追新增从这里开始")
    XCTAssertTrue(opened.beginRequest(), "SM9 打开后可以继续发起")
    XCTAssertTrue(opened.apply(snapshot(5, [event(4)])) == .merged(added: 1), "SM9 追新增只并进新的那部分")
    XCTAssertTrue(opened.events.map(\.seq) == [1, 2, 3, 4], "SM9 新事件续在窗口之后")

    // MARK: SM10 再来一次「打开」是替换，不是叠加

    let verdictReopen = opened.open(with: window(2, 5, [event(2), event(3), event(4)], hasOlder: true))
    XCTAssertTrue(verdictReopen == .merged(added: 3), "SM10 刷新以服务端给的窗口为准")
    XCTAssertTrue(opened.events.map(\.seq) == [2, 3, 4], "SM10 旧内容整段被换掉，而不是叠上去")

    // MARK: SM11 往回翻：前插，末尾位置不动

    var paged = SessionMirror()
    _ = paged.open(with: window(4, 6, [event(4), event(5)], hasOlder: true))
    let verdictOlder = paged.prepend(window(2, 4, [event(2), event(3)], hasOlder: true))
    XCTAssertTrue(verdictOlder == .merged(added: 2), "SM11 更早的一段接上了")
    XCTAssertTrue(paged.events.map(\.seq) == [2, 3, 4, 5], "SM11 更早的事件排在前面")
    XCTAssertTrue(paged.cursor == 6, "SM11 往回翻不改变末尾位置")
    XCTAssertTrue(paged.pageStart == 2, "SM11 窗口起点跟着前移")

    // MARK: SM12 往回翻一段接不上的 ⇒ 判定缺口

    var mismatched = SessionMirror()
    _ = mismatched.open(with: window(4, 6, [event(4), event(5)], hasOlder: true))
    let verdictMismatch = mismatched.prepend(window(0, 3, [event(0), event(1), event(2)], hasOlder: false))
    XCTAssertTrue(verdictMismatch == .resetRequired(.gap), "SM12 末尾接不上起点 ⇒ 中间有洞，宁可重置")
    XCTAssertTrue(mismatched.events.map(\.seq) == [4, 5], "SM12 判定为缺口时视图不动")

    // MARK: SM13 翻到日志开头：hasOlder 归假

    var exhausted = SessionMirror()
    _ = exhausted.open(with: window(2, 4, [event(2), event(3)], hasOlder: true))
    let verdictFirst = exhausted.prepend(window(0, 2, [event(0), event(1)], hasOlder: false))
    XCTAssertTrue(verdictFirst == .merged(added: 2), "SM13 最后一段也能接上")
    XCTAssertTrue(exhausted.hasOlder == false, "SM13 到头了就说明白，界面据此收起入口")
    XCTAssertTrue(exhausted.events.map(\.seq) == [0, 1, 2, 3], "SM13 覆盖了整份日志")

    // MARK: SM14 空窗口是一份合法的答案

    var blank = SessionMirror()
    let verdictBlank = blank.open(with: window(0, 0, [], hasOlder: false))
    XCTAssertTrue(verdictBlank == .caughtUp, "SM14 空日志不是错误")
    XCTAssertTrue(blank.isEmpty && !blank.hasOlder, "SM14 空视图且没有更早的")

    // MARK: SM15 重连重对齐：本地更早的部分原样保留（R10 期1 决定 1 / 决定 3）

    // 真机现场：用户往回翻到日志开头（本地因此是整份日志、hasOlder 已归假），一次传输层
    // 重连送来一个新窗口 —— 它的起点落在本地内部。旧码整段替换，于是那几页连同「读到哪」
    // 一起丢了；重对齐只换尾部。
    var following = SessionMirror()
    _ = following.open(with: window(0, 10, (0..<10).map(event), hasOlder: false))
    let verdictRealign = following.realign(with: window(6, 14, (6..<14).map(event), hasOlder: true))
    XCTAssertTrue(verdictRealign == .merged(added: 4), "SM15 新增只算新覆盖到的那几条，不是整个窗口的长度")
    XCTAssertTrue(following.events.map(\.seq) == Array(0..<14), "SM15 本地更早的 0..5 原样在，尾部换成新窗口")
    XCTAssertTrue(following.pageStart == 0, "SM15 左端没动，起点就不动")
    XCTAssertTrue(following.hasOlder == false, "SM15 已经翻到顶，重连不该让「加载更早」重新长出来")
    XCTAssertTrue(following.cursor == 14, "SM15 末尾跟着新窗口前进")

    // MARK: SM16 新窗口起点更早 ⇒ 整组采用（服务端给得更全）

    // 与 SM15 相对的另一支：新窗口的起点比本地还早（服务端窗口变大、或本地只拿到很少）。
    // 这时它覆盖了本地，没有可保留的部分 —— 左端坐标改由服务端说了算。
    var widened = SessionMirror()
    _ = widened.open(with: window(6, 10, (6..<10).map(event), hasOlder: true))
    let verdictWidened = widened.realign(with: window(2, 14, (2..<14).map(event), hasOlder: true))
    XCTAssertTrue(verdictWidened == .merged(added: 8), "SM16 新窗口覆盖得更早，净增 = 新条数减被换掉的")
    XCTAssertTrue(widened.pageStart == 2, "SM16 起点跟着新窗口前移")
    XCTAssertTrue(widened.events.map(\.seq) == Array(2..<14), "SM16 事件与新窗口逐条相同")
    XCTAssertTrue(widened.hasOlder == true, "SM16 左端变了之后，左端坐标也由新窗口给")

    // MARK: SM17 接不上 ⇒ 沿用既有的重置判定，且一条都不动

    var gapped = SessionMirror()
    _ = gapped.open(with: window(0, 10, (0..<10).map(event), hasOlder: false))
    let verdictGapped = gapped.realign(with: window(12, 14, (12..<14).map(event), hasOlder: false))
    XCTAssertTrue(verdictGapped == .resetRequired(.gap), "SM17 新窗口起点越过本地末尾 ⇒ 中间有洞，宁可重置")
    XCTAssertTrue(gapped.events.map(\.seq) == Array(0..<10), "SM17 判定缺口时视图一条不动")
    XCTAssertTrue(gapped.cursor == 10 && gapped.pageStart == 0 && gapped.hasOlder == false,
                  "SM17 判定缺口时位置也不动")

    var rewound = SessionMirror()
    _ = rewound.open(with: window(0, 10, (0..<10).map(event), hasOlder: true))
    let verdictRewound = rewound.realign(with: window(0, 8, (0..<8).map(event), hasOlder: true))
    XCTAssertTrue(verdictRewound == .resetRequired(.waterMarkWentBack), "SM17 新窗口末尾比本地还靠前 ⇒ 位置不可信")
    XCTAssertTrue(rewound.events.map(\.seq) == Array(0..<10), "SM17 水位倒退时视图也不动")

    // MARK: SM18 同一条 opening 再来一次：幂等，不累积偏差

    var redelivered = SessionMirror()
    _ = redelivered.open(with: window(0, 10, (0..<10).map(event), hasOlder: false))
    let recon = window(6, 14, (6..<14).map(event), hasOlder: true)
    _ = redelivered.realign(with: recon)
    let afterFirst = redelivered.events.map(\.seq)
    let verdictAgain = redelivered.realign(with: recon)
    XCTAssertTrue(verdictAgain == .merged(added: 0), "SM18 第二次重对齐一条也不新增")
    XCTAssertTrue(redelivered.events.map(\.seq) == afterFirst, "SM18 事件序列与第一次逐条相同")
    XCTAssertTrue(redelivered.cursor == 14 && redelivered.pageStart == 0, "SM18 位置不累积偏差")
  }
}

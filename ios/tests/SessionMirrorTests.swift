/**
 * SessionMirror 的契约测试（SM1–SM19）与「对不上」告知状态机的测试（SM20–SM21）：
 * 状态机不碰网络 / UI / 持久化，每条断言由状态机自决。
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

  /**
   一屏历史 —— 协议形状，状态机直接吃它。

   `cut` 是回包的 `cursor`（**含端**切点）：打开帧里它等于这一屏的末尾，分页回包里它是
   `throughSeq`（日志当时覆盖到哪），**可以大于本页末尾** —— 夹具按后者的真实情形给值，
   否则「拿 `cursor` 当页尾」这类错法会被夹具掩成绿。
   */
  private func window(_ cut: Int, _ events: [SessionEvent], hasMore: Bool = false) -> SessionWindow {
    SessionWindow(
      records: events.map { SessionRecord(type: "event", event: $0) },
      cursor: cut,
      hasMore: hasMore
    )
  }

  /// 请求失败必须放掉在途标记 —— 否则这个镜像之后再也发不出请求。
  ///
  /// 守的是「失败路径也要还发起权」：`beginRequest` 拿到的权只由三条落地路径
  /// （`open` / `prepend` / `apply`）还回来，抛异常时那三条都不执行。没有 `abandonRequest`，
  /// 一次网络抖动就会让「加载更早」永久失灵，而且看起来像是点了没反应。
  func testAbandonRequestReleasesTheGate() {
    var mirror = SessionMirror()
    XCTAssertTrue(mirror.beginRequest(), "首次可发起")
    XCTAssertFalse(mirror.beginRequest(), "在途时不许并发")
    mirror.abandonRequest()
    XCTAssertTrue(mirror.beginRequest(), "失败后必须能再发起")
  }

  func testContract() {
    // MARK: SM1 实时事件按序并进

    // 打开一屏，然后事件一条条到 —— 序号相接就接上，探测的是「视图与 `frontier` 同步推进」。
    var mirror = SessionMirror()
    _ = mirror.open(with: window(1, [event(0), event(1)]))
    // 切点含端：`cursor` 1 覆盖到 seq 1，下一个期望的就是 2。
    XCTAssertTrue(mirror.append(event(2)) == .merged(added: 1), "接得上的一条记为 1 条新增")
    XCTAssertTrue(mirror.frontier == 3, "位置跟着事件前进")
    XCTAssertTrue(mirror.events.map(\.seq) == [0, 1, 2], "视图按 seq 连续")

    // MARK: SM2 重复的事件丢掉

    // 重连之后上游重发一条已在视图里的事件：丢弃，不写第二遍，也不判缺口。
    let beforeRepeat = mirror.events
    XCTAssertTrue(mirror.append(event(1)) == .caughtUp, "重复的 seq 不是新增")
    XCTAssertTrue(mirror.events == beforeRepeat, "视图逐字节不变")

    // MARK: SM3 跳号判缺口，且不动视图

    let beforeGap = mirror.events
    XCTAssertTrue(mirror.append(event(9)) == .resetRequired(.gap), "跳过的 seq ⇒ 中间有洞")
    XCTAssertTrue(mirror.events == beforeGap, "判定不等于自动改视图：调用方重置前一律不动")
    XCTAssertTrue(mirror.frontier == 3, "判定本身也不动位置")

    // MARK: SM4 翻页在途时事件照常进

    // 事件不是对某次请求的回应 —— 翻页在途时它不该被闸门挡住，也不该松开那个闸门。
    var paging = SessionMirror()
    _ = paging.open(with: window(1, [event(0), event(1)]))
    XCTAssertTrue(paging.beginRequest(), "翻页拿到发起权")
    XCTAssertTrue(paging.append(event(2)) == .merged(added: 1), "在途时事件照常并进")
    XCTAssertTrue(paging.events.map(\.seq) == [0, 1, 2], "事件进得去")
    XCTAssertFalse(paging.beginRequest(), "事件不松开翻页的闸门")

    // MARK: SM9 打开会话：窗口替换整个视图，之后接着追新增

    var opened = SessionMirror()
    XCTAssertTrue(opened.isEmpty, "SM9 新镜像里什么都没有")
    let verdictOpen = opened.open(with: window(3, [event(1), event(2), event(3)], hasMore: true))
    XCTAssertTrue(verdictOpen == .merged(added: 3), "SM9 打开会话合并了整段窗口")
    XCTAssertTrue(opened.windowStart == 1 && opened.hasMore, "SM9 窗口起点与「还有更早的」都记下了")
    XCTAssertTrue(opened.frontier == 4, "SM9 位置落在窗口末尾，追新增从这里开始")
    XCTAssertTrue(opened.beginRequest(), "SM9 打开后可以继续发起")
    XCTAssertTrue(opened.append(event(4)) == .merged(added: 1), "SM9 追新增续在窗口之后")
    XCTAssertTrue(opened.events.map(\.seq) == [1, 2, 3, 4], "SM9 新事件续在窗口之后")

    // MARK: SM10 再来一次「打开」是替换，不是叠加

    let verdictReopen = opened.open(with: window(4, [event(2), event(3), event(4)], hasMore: true))
    XCTAssertTrue(verdictReopen == .merged(added: 3), "SM10 刷新以服务端给的窗口为准")
    XCTAssertTrue(opened.events.map(\.seq) == [2, 3, 4], "SM10 旧内容整段被换掉，而不是叠上去")

    // MARK: SM11 往回翻：前插，末尾位置不动

    var paged = SessionMirror()
    _ = paged.open(with: window(5, [event(4), event(5)], hasMore: true))
    let verdictOlder = paged.prepend(window(5, [event(2), event(3)], hasMore: true))
    XCTAssertTrue(verdictOlder == .merged(added: 2), "SM11 更早的一段接上了")
    XCTAssertTrue(paged.events.map(\.seq) == [2, 3, 4, 5], "SM11 更早的事件排在前面")
    XCTAssertTrue(paged.frontier == 6, "SM11 往回翻不改变末尾位置")
    XCTAssertTrue(paged.windowStart == 2, "SM11 窗口起点跟着前移")
    XCTAssertTrue(paged.throughSeq == 5, "SM11 切点不动 —— 它钉的是打开那一刻日志到哪")

    // MARK: SM12 往回翻一段接不上的 ⇒ 判定缺口

    var mismatched = SessionMirror()
    _ = mismatched.open(with: window(5, [event(4), event(5)], hasMore: true))
    let verdictMismatch = mismatched.prepend(window(5, [event(0), event(1), event(2)], hasMore: false))
    XCTAssertTrue(verdictMismatch == .resetRequired(.gap), "SM12 末尾接不上起点 ⇒ 中间有洞，宁可重置")
    XCTAssertTrue(mismatched.events.map(\.seq) == [4, 5], "SM12 判定为缺口时视图不动")

    // MARK: SM12b 与网关 `page-forward` 的样本同形：`cursor` 远大于本页末尾也能接上

    // 网关那条判据的回包是 `{records: [seq 6], cursor: 129, hasMore: true}`（`beforeSeq: 7`）。
    // 拿 `cursor` 当页尾比会判成缺口 —— 这一条就是那个错法的现场复现。
    var sameAsGateway = SessionMirror()
    _ = sameAsGateway.open(with: window(129, (7..<130).map(event), hasMore: true))
    let verdictGatewayShape = sameAsGateway.prepend(window(129, [event(6)], hasMore: true))
    XCTAssertTrue(verdictGatewayShape == .merged(added: 1),
                  "回包的 `cursor`（129）不是这一页的末尾（6）—— 接续看 `records.last`")
    XCTAssertTrue(sameAsGateway.events.first?.seq == 6, "更早的那条排在最前")

    // MARK: SM13 翻到日志开头：hasMore 归假

    var exhausted = SessionMirror()
    _ = exhausted.open(with: window(3, [event(2), event(3)], hasMore: true))
    let verdictFirst = exhausted.prepend(window(3, [event(0), event(1)], hasMore: false))
    XCTAssertTrue(verdictFirst == .merged(added: 2), "SM13 最后一段也能接上")
    XCTAssertTrue(exhausted.hasMore == false, "SM13 到头了就说明白，界面据此收起入口")
    XCTAssertTrue(exhausted.events.map(\.seq) == [0, 1, 2, 3], "SM13 覆盖了整份日志")

    // MARK: SM14 空窗口是一份合法的答案

    var blank = SessionMirror()
    let verdictBlank = blank.open(with: window(-1, [], hasMore: false))
    XCTAssertTrue(verdictBlank == .caughtUp, "SM14 空日志不是错误")
    XCTAssertTrue(blank.isEmpty && !blank.hasMore, "SM14 空视图且没有更早的")
    XCTAssertTrue(blank.windowStart == 0 && blank.frontier == 0,
                  "SM14 空窗口的两个位置都是 0（`cursor = -1` 的 +1 换算只在一处）")
    XCTAssertTrue(blank.throughSeq == -1, "SM14 空日志的切点是 -1，不是 0")

    // MARK: SM15 重连重对齐：本地更早的部分原样保留

    // 真机现场：用户往回翻到日志开头（本地因此是整份日志、hasMore 已归假），一次传输层
    // 重连送来一个新窗口 —— 它的起点落在本地内部。旧码整段替换，于是那几页连同「读到哪」
    // 一起丢了；重对齐只换尾部。
    var following = SessionMirror()
    _ = following.open(with: window(9, (0..<10).map(event), hasMore: false))
    let verdictRealign = following.realign(with: window(13, (6..<14).map(event), hasMore: true))
    XCTAssertTrue(verdictRealign == .merged(added: 4), "SM15 新增只算新覆盖到的那几条，不是整个窗口的长度")
    XCTAssertTrue(following.events.map(\.seq) == Array(0..<14), "SM15 本地更早的 0..5 原样在，尾部换成新窗口")
    XCTAssertTrue(following.windowStart == 0, "SM15 左端没动，起点就不动")
    XCTAssertTrue(following.hasMore == false, "SM15 已经翻到顶，重连不该让「加载更早」重新长出来")
    XCTAssertTrue(following.frontier == 14, "SM15 末尾跟着新窗口前进")

    // MARK: SM16 新窗口起点更早 ⇒ 整组采用（服务端给得更全）

    // 与 SM15 相对的另一支：新窗口的起点比本地还早（服务端窗口变大、或本地只拿到很少）。
    // 这时它覆盖了本地，没有可保留的部分 —— 左端坐标改由服务端说了算。
    var widened = SessionMirror()
    _ = widened.open(with: window(9, (6..<10).map(event), hasMore: true))
    let verdictWidened = widened.realign(with: window(13, (2..<14).map(event), hasMore: true))
    XCTAssertTrue(verdictWidened == .merged(added: 8), "SM16 新窗口覆盖得更早，净增 = 新条数减被换掉的")
    XCTAssertTrue(widened.windowStart == 2, "SM16 起点跟着新窗口前移")
    XCTAssertTrue(widened.events.map(\.seq) == Array(2..<14), "SM16 事件与新窗口逐条相同")
    XCTAssertTrue(widened.hasMore == true, "SM16 左端变了之后，左端坐标也由新窗口给")

    // MARK: SM17 接不上 ⇒ 沿用既有的重置判定，且一条都不动

    var gapped = SessionMirror()
    _ = gapped.open(with: window(9, (0..<10).map(event), hasMore: false))
    let verdictGapped = gapped.realign(with: window(13, (12..<14).map(event), hasMore: false))
    XCTAssertTrue(verdictGapped == .resetRequired(.gap), "SM17 新窗口起点越过本地末尾 ⇒ 中间有洞，宁可重置")
    XCTAssertTrue(gapped.events.map(\.seq) == Array(0..<10), "SM17 判定缺口时视图一条不动")
    XCTAssertTrue(gapped.frontier == 10 && gapped.windowStart == 0 && gapped.hasMore == false,
                  "SM17 判定缺口时位置也不动")

    var rewound = SessionMirror()
    _ = rewound.open(with: window(9, (0..<10).map(event), hasMore: true))
    let verdictRewound = rewound.realign(with: window(7, (0..<8).map(event), hasMore: true))
    XCTAssertTrue(verdictRewound == .resetRequired(.waterMarkWentBack), "SM17 新窗口末尾比本地还靠前 ⇒ 位置不可信")
    XCTAssertTrue(rewound.events.map(\.seq) == Array(0..<10), "SM17 水位倒退时视图也不动")

    // MARK: SM18 同一条 opening 再来一次：幂等，不累积偏差

    var redelivered = SessionMirror()
    _ = redelivered.open(with: window(9, (0..<10).map(event), hasMore: false))
    let recon = window(13, (6..<14).map(event), hasMore: true)
    _ = redelivered.realign(with: recon)
    let afterFirst = redelivered.events.map(\.seq)
    let verdictAgain = redelivered.realign(with: recon)
    XCTAssertTrue(verdictAgain == .merged(added: 0), "SM18 第二次重对齐一条也不新增")
    XCTAssertTrue(redelivered.events.map(\.seq) == afterFirst, "SM18 事件序列与第一次逐条相同")
    XCTAssertTrue(redelivered.frontier == 14 && redelivered.windowStart == 0, "SM18 位置不累积偏差")

    // MARK: SM19 「对不上」分两档：本地位置有没有被服务端否定

    // 这一档决定「保留本地」还是「清空重来」：本地那段仍然是真的 ⇒ 保住它；位置被否定 ⇒ 它可能不是
    // 真的，宁可重置。
    XCTAssertTrue(ResetReason.gap.invalidatesLocalContent == false,
                  "SM19 两段之间有洞 —— 本地那段本身仍是真的，不算否定位置")
    XCTAssertTrue(ResetReason.waterMarkWentBack.invalidatesLocalContent == true,
                  "SM19 服务端给的位置比本地还靠前 ⇒ 本地位置被否定")

    // MARK: SM20 「未接上」的说明不被一次接得上的重连抹掉

    var notices = ResyncNoticeState()
    notices.observe(.resetRequired(.gap))
    XCTAssertTrue(notices.notice == ResyncNotice(kind: .unresolved, reason: .gap),
                  "SM20 保留分支 ⇒ 说明是「未接上」，并带上原因")
    notices.observe(.merged(added: 0))
    XCTAssertTrue(notices.notice == ResyncNotice(kind: .unresolved, reason: .gap),
                  "SM20 随后一次接得上的重连不清除它 —— 洞还在，界面不该假装没事")

    // MARK: SM21 接得上的判定不置位；置位之后只由「离开再进入」清除

    var resetNotices = ResyncNoticeState()
    resetNotices.observe(.merged(added: 3))
    XCTAssertTrue(resetNotices.notice == nil, "SM21 接得上的判定不自己置位")
    resetNotices.observe(.resetRequired(.waterMarkWentBack))
    XCTAssertTrue(resetNotices.notice == ResyncNotice(kind: .reset, reason: .waterMarkWentBack),
                  "SM21 位置被否定 ⇒ 说明是「已重置」，并带上原因")
    resetNotices.observe(.merged(added: 1))
    XCTAssertTrue(resetNotices.notice == ResyncNotice(kind: .reset, reason: .waterMarkWentBack),
                  "SM21 没有清除口 —— 一条告警在这一屏里一直是真的，清除靠整屏重建")
  }
}

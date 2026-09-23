/**
 * SessionMirror 的契约测试（SM1–SM14）。
 *
 * 状态机不碰网络、不碰 UI、不碰持久化，所以这里没有服务器、没有 DSH 运行时、
 * 没有文件系统 —— 每条断言都由状态机自己决定。跑法见同目录的 `run.sh`。
 *
 * 断言清单与出处：docs/dev/plans/M1-consistency-delta.md §5.1（SM1–SM14）。
 */
import Foundation

@main
struct SessionMirrorTests {

  /** 一条事件：`seq` 参与判定，其余字段原样带着。 */
  private static func event(_ seq: Int) -> SessionEvent {
    SessionEvent(
      type: "user/message",
      seq: seq,
      time: 1_758_000_000_000 + Double(seq),
      data: .object(["body": .string("#\(seq)")])
    )
  }

  /** 一段往回读的窗口。 */
  private static func window(_ pageStart: Int, _ asOfSeq: Int, _ events: [SessionEvent], hasOlder: Bool = false) -> Window {
    Window(pageStart: pageStart, asOfSeq: asOfSeq, hasOlder: hasOlder, events: events)
  }

  private static func snapshot(_ asOfSeq: Int, _ events: [SessionEvent], hasMore: Bool = false) -> Outcome {
    .received(Snapshot(asOfSeq: asOfSeq, hasMore: hasMore, events: events))
  }

  static func main() {
    // MARK: SM1 首次合并

    // 分两批拉，覆盖「分块推进」：第一批 hasMore 为真，游标落在本批末尾。
    var mirror = SessionMirror()
    expect(mirror.beginRequest(), "SM1 首次请求可以发起")
    let firstBatch = mirror.apply(snapshot(2, [event(0), event(1)], hasMore: true))
    expect(firstBatch == .merged(added: 2), "SM1 第一批记为 2 条新增")
    expect(mirror.cursor == 2, "SM1 游标落在本批末尾（不是整个日志的末尾）")

    expect(mirror.beginRequest(), "SM1 第二批可以接着发起")
    let secondBatch = mirror.apply(snapshot(3, [event(2)]))
    expect(secondBatch == .merged(added: 1), "SM1 第二批记为 1 条新增")
    expect(mirror.events.count == 3, "SM1 两批合起来事件全收")
    expect(mirror.cursor == 3, "SM1 游标等于服务端给的 asOfSeq")

    // MARK: SM2 空增量

    let viewBefore = mirror.events
    expect(mirror.beginRequest(), "SM2 可以发起")
    let verdictCaughtUp = mirror.apply(snapshot(3, []))
    expect(verdictCaughtUp == .caughtUp, "SM2 判定为已追平")
    expect(mirror.events == viewBefore, "SM2 视图逐字节不变")
    expect(mirror.cursor == 3, "SM2 游标不变")

    // MARK: SM3 缺口

    expect(mirror.beginRequest(), "SM3 可以发起")
    let verdictGap = mirror.apply(snapshot(5, [event(4)]))
    expect(verdictGap == .resetRequired(.gap), "SM3 首批 seq 跳过了游标 ⇒ 判定存在缺口")
    expect(mirror.cursor == 3, "SM3 判定不等于自动重置：游标在调用方重置前不动")

    // MARK: SM4 幂等

    // 整批重复投递：首批的 seq 小于游标。这里不能判成缺口 —— 它已经在视图里了。
    var idempotent = SessionMirror()
    _ = idempotent.beginRequest()
    _ = idempotent.apply(snapshot(3, [event(0), event(1), event(2)]))
    let beforeRepeat = idempotent.events

    _ = idempotent.beginRequest()
    let repeated = idempotent.apply(snapshot(3, [event(0), event(1), event(2)]))
    expect(repeated == .caughtUp, "SM4 整批重复投递不产生新增")
    expect(idempotent.events == beforeRepeat, "SM4 事件不重复")
    expect(idempotent.events.count == 3, "SM4 视图仍是 3 条")

    // 部分重叠：前半重复、后半是新的 —— 重复的丢掉，新的照收。
    _ = idempotent.beginRequest()
    let overlap = idempotent.apply(snapshot(5, [event(2), event(3), event(4)]))
    expect(overlap == .merged(added: 2), "SM4 部分重叠时只算新增的两条")
    expect(idempotent.events.count == 5, "SM4 重叠部分没有被写第二遍")
    expect(idempotent.events.map(\.seq) == [0, 1, 2, 3, 4], "SM4 视图按 seq 连续")

    // MARK: SM5 水位倒退

    let cursorBefore = idempotent.cursor
    _ = idempotent.beginRequest()
    let wentBack = idempotent.apply(snapshot(cursorBefore - 1, []))
    expect(wentBack == .resetRequired(.waterMarkWentBack), "SM5 asOfSeq 小于游标 ⇒ 判定水位倒退")
    expect(idempotent.cursor == cursorBefore, "SM5 判定本身不动游标")

    // MARK: SM6 游标作废

    _ = idempotent.beginRequest()
    let voided = idempotent.apply(.refused(Refusal(code: "resync-required", message: "since cannot exist")))
    expect(voided == .resetRequired(.cursorVoid), "SM6 resync-required ⇒ 判定游标作废")
    idempotent.reset()
    expect(idempotent.cursor == 0 && idempotent.events.isEmpty, "SM6 重置后丢弃游标与视图，以 0 重来")

    // 其它错误码只是拒绝，不要求重置。
    _ = idempotent.beginRequest()
    let other = idempotent.apply(.refused(Refusal(code: "unknown-session", message: "no such session")))
    expect(other == .refused(code: "unknown-session"), "SM6 其它错误码只作拒绝")

    // MARK: SM7 投递失败

    var fragile = SessionMirror()
    _ = fragile.beginRequest()
    _ = fragile.apply(snapshot(3, [event(0), event(1), event(2)]))
    let intactEvents = fragile.events
    let intactCursor = fragile.cursor

    _ = fragile.beginRequest()
    let incomplete = fragile.apply(.transportFailed)
    expect(incomplete == .failed, "SM7 传输失败判定为失败")
    expect(fragile.events == intactEvents, "SM7 视图不含半截数据")
    expect(fragile.cursor == intactCursor, "SM7 游标不动")

    // MARK: SM8 单飞

    var single = SessionMirror()
    expect(single.beginRequest(), "SM8 第一次发起成功")
    expect(!single.beginRequest(), "SM8 在途时第二次发起被拒绝")
    _ = single.apply(snapshot(1, [event(0)]))
    expect(single.beginRequest(), "SM8 响应返回后可以再次发起")

    // 在途时再发起被拒，也不得产生第二次合并 —— 用「被拒的请求没有响应可合并」体现。
    expect(single.events.count == 1, "SM8 被拒的那次没有改动视图")

    // MARK: SM9 打开会话：窗口替换整个视图，之后接着追新增

    var opened = SessionMirror()
    expect(opened.isEmpty, "SM9 新镜像里什么都没有")
    let verdictOpen = opened.open(with: window(1, 4, [event(1), event(2), event(3)], hasOlder: true))
    expect(verdictOpen == .merged(added: 3), "SM9 打开会话合并了整段窗口")
    expect(opened.pageStart == 1 && opened.hasOlder, "SM9 窗口起点与「还有更早的」都记下了")
    expect(opened.cursor == 4, "SM9 位置落在窗口末尾，追新增从这里开始")
    expect(opened.beginRequest(), "SM9 打开后可以继续发起")
    expect(opened.apply(snapshot(5, [event(4)])) == .merged(added: 1), "SM9 追新增只并进新的那部分")
    expect(opened.events.map(\.seq) == [1, 2, 3, 4], "SM9 新事件续在窗口之后")

    // MARK: SM10 再来一次「打开」是替换，不是叠加

    let verdictReopen = opened.open(with: window(2, 5, [event(2), event(3), event(4)], hasOlder: true))
    expect(verdictReopen == .merged(added: 3), "SM10 刷新以服务端给的窗口为准")
    expect(opened.events.map(\.seq) == [2, 3, 4], "SM10 旧内容整段被换掉，而不是叠上去")

    // MARK: SM11 往回翻：前插，末尾位置不动

    var paged = SessionMirror()
    _ = paged.open(with: window(4, 6, [event(4), event(5)], hasOlder: true))
    let verdictOlder = paged.prepend(window(2, 4, [event(2), event(3)], hasOlder: true))
    expect(verdictOlder == .merged(added: 2), "SM11 更早的一段接上了")
    expect(paged.events.map(\.seq) == [2, 3, 4, 5], "SM11 更早的事件排在前面")
    expect(paged.cursor == 6, "SM11 往回翻不改变末尾位置")
    expect(paged.pageStart == 2, "SM11 窗口起点跟着前移")

    // MARK: SM12 往回翻一段接不上的 ⇒ 判定缺口

    var mismatched = SessionMirror()
    _ = mismatched.open(with: window(4, 6, [event(4), event(5)], hasOlder: true))
    let verdictMismatch = mismatched.prepend(window(0, 3, [event(0), event(1), event(2)], hasOlder: false))
    expect(verdictMismatch == .resetRequired(.gap), "SM12 末尾接不上起点 ⇒ 中间有洞，宁可重置")
    expect(mismatched.events.map(\.seq) == [4, 5], "SM12 判定为缺口时视图不动")

    // MARK: SM13 翻到日志开头：hasOlder 归假

    var exhausted = SessionMirror()
    _ = exhausted.open(with: window(2, 4, [event(2), event(3)], hasOlder: true))
    let verdictFirst = exhausted.prepend(window(0, 2, [event(0), event(1)], hasOlder: false))
    expect(verdictFirst == .merged(added: 2), "SM13 最后一段也能接上")
    expect(exhausted.hasOlder == false, "SM13 到头了就说明白，界面据此收起入口")
    expect(exhausted.events.map(\.seq) == [0, 1, 2, 3], "SM13 覆盖了整份日志")

    // MARK: SM14 空窗口是一份合法的答案

    var blank = SessionMirror()
    let verdictBlank = blank.open(with: window(0, 0, [], hasOlder: false))
    expect(verdictBlank == .caughtUp, "SM14 空日志不是错误")
    expect(blank.isEmpty && !blank.hasOlder, "SM14 空视图且没有更早的")

    print("\n\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
  }
}

/**
 * 客户端侧的会话镜像 —— 一台纯状态机。
 *
 * 它不碰网络、不碰 UI、也不碰磁盘：输入是「本地视图 + 服务端的一次回应」，输出是
 * 「新视图 + 一条判定」。之所以把它单独拿出来，是因为**校验责任在客户端**
 * （服务端是匿名的一次性请求，没有地方存放「这台设备读到哪了」），而校验逻辑
 * 一旦和 URLSession 或界面缠在一起就没法单独验证。分开之后，它既能被 iOS
 * target 编译，也能被 `swiftc` 直接编成 macOS 命令行程序跑断言。
 *
 * ## 三种进入方式，两个方向
 *
 * | 动作 | 服务端消息 | 对视图的作用 |
 * |---|---|---|
 * | 打开会话 | `page`（不带 `beforeSeq`） | **替换**成最新的一个窗口 |
 * | 往回翻 | `page`（带 `beforeSeq`） | 把更早的一段**前插** |
 * | 追新增 | `snapshot`（带 `since`） | 往后**追加** |
 *
 * ## 为什么不落盘
 *
 * 镜像只在进程内存在：没有任何位置或内容跨进程存活。代价是冷启动要重新取一个
 * 窗口，换来的是**不存在**「磁盘里那份内容已经过期、看起来却和完整的一样」这种
 * 状态。本项目还没有新鲜度表达（那是另一期的事），所以这类状态一旦存在就没法
 * 被客户端自己识破 —— 不存它，比存它再想办法识别它更可靠。
 *
 * 事件类型直接用协议层的 `SessionEvent`，不自造一个「镜像事件」：状态机要判的
 * 只是 `seq`，而视图要渲染的是同一批事件 —— 中间再隔一层映射，就得在两个方向上
 * 各写一次转换，而转换正是「两边不是同一份」最容易发生的地方。
 *
 * 上游有等价的语义（`RemoteJournalStream` 的「丢重复、拒缺口、钉 cut」，以及
 * `page` 的往回翻），但那是 TypeScript，代码用不了 —— 这里照它的语义重写最小的一段。
 *
 * 出处：docs/dev/plans/M1-consistency-delta.md §3.3.2 决定 2 / 决定 9；契约见 docs/dev/protocol.md。
 */

/// 一次 `snapshot` 成功响应的内容。
struct Snapshot: Equatable {
  /// 本次回应覆盖到的位置（不含）—— 即回传它作下一次的 `since`。
  let asOfSeq: Int
  /// 服务端是否还有没给完的事件。
  let hasMore: Bool
  let events: [SessionEvent]
}

/// 一段往回读的窗口（协议 §4.3）。
struct Window: Equatable {
  /// 窗口首个事件的 `seq` —— 即下一次往回翻时的 `beforeSeq`。
  let pageStart: Int
  /// 窗口末尾（不含）。
  let asOfSeq: Int
  /// 窗口之前还有事件吗。
  let hasOlder: Bool
  let events: [SessionEvent]
}

/// 一次被拒绝的响应。
struct Refusal: Equatable {
  let code: String
  let message: String
}

/// 一次请求的三种结局。做成枚举而不是可选值，是因为「没有响应」和「被拒绝」
/// 对视图的影响不同：前者什么都不能改，后者可能要重置。
enum Outcome: Equatable {
  case received(Snapshot)
  case refused(Refusal)
  /// 传输层失败：连接断了、超时、进程被杀 —— 没有任何服务端结论。
  case transportFailed
}

/// 需要重置的理由。三种都归结为同一动作（丢弃位置与视图，重新取窗口），但保留
/// 区分是为了让界面能如实说明发生了什么。
enum ResetReason: Equatable {
  /// 事件的 `seq` 跳过了已有内容 —— 中间有事件没拿到。
  case gap
  /// 服务端给的位置比本地还靠前 —— 本地视图不可信。
  case waterMarkWentBack
  /// 服务端明确拒绝了这个位置（`resync-required`）。
  case cursorVoid
}

/// 一次合并的判定。调用方据它决定界面显示什么。
enum Verdict: Equatable {
  case merged(added: Int)
  case caughtUp
  case resetRequired(ResetReason)
  case refused(code: String)
  case failed
}

/// 一个会话的镜像状态。
///
/// **位置只能由这几个合并方法推进。** 上游有一条对应的禁止规则（「UI 动作永不
/// 推进游标」），这里的实现方式不是加检查，而是**不提供入口**：位置字段对调用方
/// 只读，而唯一会改它们的方法都要求一份来自服务端的回应。下拉刷新、切屏、列表
/// 刷新完成都不经过它们，因此不可能把「还没拿到的变更」当成已消费。
struct SessionMirror {

  /// 下一个期望的 `seq` —— 已有内容的末尾。`0` 表示「我什么都没有」。
  private(set) var cursor: Int = 0

  /// 当前窗口首个事件的 `seq`。往回翻时把它当 `beforeSeq` 传出去。
  private(set) var pageStart: Int = 0

  /// 窗口之前还有没有事件。为假表示已经到日志开头。
  private(set) var hasOlder = false

  /// 已落地的视图。按 `seq` 连续，且不含重复。
  private(set) var events: [SessionEvent] = []

  /// 是否有在途请求。同一会话同时只允许一个。
  private var inFlight = false

  /// 服务端表示位置不可用时使用的错误码。
  private static let resyncRequired = "resync-required"

  /// 还没有任何内容 —— 冷启动、或刚被重置。
  var isEmpty: Bool { events.isEmpty }

  /// 发起请求的门。同一会话同时只允许一个在途请求 —— 否则两个响应会各自基于
  /// 同一个旧位置独立判定，落地的先后顺序就没有保证了。
  /// - Returns: 是否拿到了发起权。
  mutating func beginRequest() -> Bool {
    guard !inFlight else { return false }
    inFlight = true
    return true
  }

  /// 打开会话：用最新的一个窗口**替换**整个视图。
  ///
  /// 覆盖两种情形：「什么都没拿过」与「已经有内容但要刷新到最新」。两者都是
  /// 「以服务端此刻给的窗口为准」，所以共用一条路径。
  /// - Parameter window: `page` 的响应，不带 `beforeSeq` 的那一种。
  /// - Returns: 本次的判定。
  mutating func open(with window: Window) -> Verdict {
    inFlight = false

    if let first = window.events.first, first.seq != window.pageStart {
      // 窗口的边界与它自己的内容对不上 —— 服务端给的这段不能用。
      return .resetRequired(.gap)
    }

    cursor = window.asOfSeq
    pageStart = window.pageStart
    hasOlder = window.hasOlder
    events = window.events
    return window.events.isEmpty ? .caughtUp : .merged(added: window.events.count)
  }

  /// 往回翻：把更早的一段**前插**到视图前面。
  ///
  /// 位置（`cursor`）不动 —— 往回翻改变的是视图的起点，不是它的末尾。
  /// - Parameter window: `page` 的响应，带 `beforeSeq` 的那一种。
  /// - Returns: 本次的判定。
  mutating func prepend(_ window: Window) -> Verdict {
    inFlight = false

    // 只接受**紧邻**的一段：它的末尾必须正好接在当前窗口的起点上。松了会让
    // 视图出现空洞，而静默地少一段比报错危险得多。
    guard window.asOfSeq == pageStart else {
      return .resetRequired(.gap)
    }

    events.insert(contentsOf: window.events, at: 0)
    pageStart = window.pageStart
    hasOlder = window.hasOlder
    return .merged(added: window.events.count)
  }

  /// 合并一次 `snapshot` 的结局：往后追新增。
  ///
  /// 失败路径一律不改动视图与位置：宁可什么都没发生，也不要半截数据 —— 一个
  /// 看起来正常但缺了几条的视图，比一次可见的失败危险得多。
  /// - Parameter outcome: 请求的三种结局之一。
  /// - Returns: 本次的判定。
  mutating func apply(_ outcome: Outcome) -> Verdict {
    inFlight = false

    switch outcome {
    case .transportFailed:
      return .failed

    case .refused(let refusal):
      // 只有「位置不可用」需要重置；其它拒绝（会话不存在、日志读不出来）是
      // 别的问题，界面照实显示即可。
      return refusal.code == Self.resyncRequired
        ? .resetRequired(.cursorVoid)
        : .refused(code: refusal.code)

    case .received(let snapshot):
      return merge(snapshot)
    }
  }

  /// 丢弃位置与视图，回到「什么都没有」。
  ///
  /// 由调用方在收到 `resetRequired` 之后调用，而不是由状态机自动执行：重置是
  /// 用户看得见的事件，界面需要机会先把「正在重新同步」表达出来。
  mutating func reset() {
    cursor = 0
    pageStart = 0
    hasOlder = false
    events = []
    inFlight = false
  }

  /// 把一次成功响应并进视图。
  ///
  /// 判定顺序是**幂等 → 水位单调 → 缺口**，顺序不能换：重复投递时首批事件的
  /// `seq` 同样小于游标，如果先判缺口，一次正常的重发就会被误判成需要重置。
  /// 先做幂等，重复的部分被丢掉之后，「首批是否等于游标」才是有意义的问。
  private mutating func merge(_ snapshot: Snapshot) -> Verdict {
    if snapshot.asOfSeq < cursor {
      return .resetRequired(.waterMarkWentBack)
    }

    // 幂等：丢掉已经在视图里的事件。重复投递与部分重叠都由这一步吸收。
    let fresh = snapshot.events.filter { $0.seq >= cursor }

    guard let first = fresh.first else {
      // 一条新的也没有。若服务端同时声称覆盖到了更远的位置，那它说的事件并不
      // 存在 —— 视图缺了这一段，重置比将就安全。
      return snapshot.asOfSeq > cursor ? .resetRequired(.gap) : .caughtUp
    }

    if first.seq > cursor {
      return .resetRequired(.gap)
    }

    // 到这里 first.seq 必然等于游标：小于它的已被幂等那一步滤掉。
    events.append(contentsOf: fresh)
    cursor = snapshot.asOfSeq
    return .merged(added: fresh.count)
  }
}

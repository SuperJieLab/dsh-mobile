/**
 * 客户端侧的会话镜像 —— 纯状态机：输入「本地视图 + 一次服务端回应」，输出「新视图 + 一条判定」。
 * 不碰网络、UI 与磁盘。校验责任在客户端：服务端是匿名的一次性请求，没处存「这台设备读到哪」。
 *
 * 打开 `page` 替换整窗；重连 opening 保留更早的段、只换尾部；往回翻 `page` 前插；追新增追加。
 * 事件与窗口直接用协议类型，不另声明一份（同形的两份只能靠逐字段搬运相连）。
 */

/// 一次被拒绝的响应。
struct Refusal: Equatable {
  let code: String
  let message: String
}

/// 一次请求的结局。用枚举而非可选值：「没有响应」与「被拒绝」对视图的影响不同。
enum Outcome: Equatable {
  case received(SessionSnapshot)
  case refused(Refusal)
  /// 传输层失败：连接断了、超时、进程被杀 —— 没有任何服务端结论。
  case transportFailed
}

/// 需要重置的理由 —— 动作同一个（丢弃位置重取窗口），保留区分是为了界面能如实说明。
enum ResetReason: Equatable {
  /// 事件的 `seq` 跳过了已有内容 —— 中间有事件没拿到。
  case gap
  /// 服务端给的位置比本地还靠前 —— 本地视图不可信。
  case waterMarkWentBack
  /// 服务端明确拒绝了这个位置（`resync-required`）。
  case cursorVoid

    /// 这一因是否**否定了本地位置本身** —— 决定「对不上」时保住本地还是清空重来。
    /// 有洞（`.gap`）时本地那段仍然是真的、只是旧：保住它并如实说「更新没接上」。
    /// 水位倒退与位置作废是服务端在说这个位置不作数，屏上内容可能根本不是这段日志 ⇒ 重置。
  var invalidatesLocalContent: Bool {
    switch self {
    case .gap: return false
    case .waterMarkWentBack, .cursorVoid: return true
    }
  }
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
/// **位置只能由这几个合并方法推进**：字段对调用方只读，唯一会改它们的方法都要求一份服务端回应。
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

  /// 还没有任何内容 —— 冷启动、或刚被重置。
  var isEmpty: Bool { events.isEmpty }

    /// 发起请求的门：同一会话同时只允许一个在途（否则两个响应各自基于旧位置判定，落地顺序无保证）。
    /// - Returns: 是否拿到了发起权。
  mutating func beginRequest() -> Bool {
    guard !inFlight else { return false }
    inFlight = true
    return true
  }

    /// 请求失败：放掉在途标记，**视图与位置一律不动**。
    /// 没有这个出口，抛异常时标记一直挂着，此后每次 `beginRequest` 都返回
    /// false——「点加载更早没反应」。
  mutating func abandonRequest() {
    inFlight = false
  }

  /// 新窗口自己的边界要与内容自洽 —— 同一条校验，`open` 与 `realign` 都过。
  private static func isSelfConsistent(_ window: SessionPage) -> Bool {
    guard let first = window.events.first else { return true }
    return first.seq == window.pageStart
  }

    /// 打开会话：用最新窗口**替换**整个视图（「什么都没拿过」与「刷新到最新」共用这条路径）。
    /// - Returns: 本次的判定。
  mutating func open(with window: SessionPage) -> Verdict {
    inFlight = false

    // 窗口的边界与它自己的内容对不上时，服务端给的这段不能用。
    guard Self.isSelfConsistent(window) else { return .resetRequired(.gap) }

    cursor = window.asOfSeq
    pageStart = window.pageStart
    hasOlder = window.hasOlder
    events = window.events
    return window.events.isEmpty ? .caughtUp : .merged(added: window.events.count)
  }

    /// 重连：新窗口与本地重对齐 —— **本地更早的部分原样保留，只换尾部**。
    /// 按新窗口起点落在哪分三支：更早或相同 ⇒ 整组采用；落在本地内部 ⇒ 保留 `seq < pageStart`
  mutating func realign(with window: SessionPage) -> Verdict {
    inFlight = false

    guard Self.isSelfConsistent(window) else { return .resetRequired(.gap) }

    // 手里什么都没有：这与「打开会话」是同一件事。
    guard !events.isEmpty else { return open(with: window) }

    if window.asOfSeq < cursor {
      return .resetRequired(.waterMarkWentBack)
    }
    if window.pageStart > cursor {
      return .resetRequired(.gap)
    }

    let before = events.count
    if window.pageStart <= pageStart {
      // 新窗口覆盖了本地（起点更早或相同）⇒ 左端跟着它走。
      pageStart = window.pageStart
      hasOlder = window.hasOlder
      events = window.events
    } else {
      // 保留本地更早的那段；它与新窗口紧邻（新起点落在本地已覆盖的范围里）⇒ 拼起来无缝。
      events = events.filter { $0.seq < window.pageStart } + window.events
    }
    cursor = window.asOfSeq

    return events.isEmpty ? .caughtUp : .merged(added: events.count - before)
  }

    /// 往回翻：把更早的一段**前插**。`cursor` 不动 —— 往回翻改的是视图起点，不是末尾。
    /// - Returns: 本次的判定。
  mutating func prepend(_ window: SessionPage) -> Verdict {
    inFlight = false

    // 只接受**紧邻**的一段：它的末尾必须正好接在当前起点上，否则视图出现空洞。
    guard window.asOfSeq == pageStart else {
      return .resetRequired(.gap)
    }

    events.insert(contentsOf: window.events, at: 0)
    pageStart = window.pageStart
    hasOlder = window.hasOlder
    return .merged(added: window.events.count)
  }

    /// 合并一次 `snapshot`：往后追新增。失败一律不改视图与位置。
    /// - Returns: 本次的判定。
  mutating func apply(_ outcome: Outcome) -> Verdict {
    inFlight = false

    switch outcome {
    case .transportFailed:
      return .failed

    case .refused(let refusal):
      // 只有「位置不可用」需要重置；其它拒绝（会话不存在、读不出来）照实显示即可。
      return refusal.code == GatewayErrorCode.resyncRequired.rawValue
        ? .resetRequired(.cursorVoid)
        : .refused(code: refusal.code)

    case .received(let snapshot):
      return merge(snapshot)
    }
  }

    /// 丢弃位置与视图。由调用方在收到 `resetRequired` 后调用 —— 重置是用户看得见的事件。
  mutating func reset() {
    cursor = 0
    pageStart = 0
    hasOlder = false
    events = []
    inFlight = false
  }

    /// 把一次成功响应并进视图。顺序是**幂等 → 水位单调 → 缺口**，不能换：重复投递时首批事件
    /// 的 `seq` 同样小于游标，先判缺口就会把正常重发误判成重置。
  private mutating func merge(_ snapshot: SessionSnapshot) -> Verdict {
    if snapshot.asOfSeq < cursor {
      return .resetRequired(.waterMarkWentBack)
    }

    // 幂等：丢掉已经在视图里的事件。重复投递与部分重叠都由这一步吸收。
    let fresh = snapshot.events.filter { $0.seq >= cursor }

    guard let first = fresh.first else {
      // 一条新的也没有，而服务端声称覆盖到更远的位置 ⇒ 视图缺了这一段，重置比将就安全。
      return snapshot.asOfSeq > cursor ? .resetRequired(.gap) : .caughtUp
    }

    if first.seq > cursor {
      return .resetRequired(.gap)
    }

    events.append(contentsOf: fresh)
    cursor = snapshot.asOfSeq
    return .merged(added: fresh.count)
  }
}

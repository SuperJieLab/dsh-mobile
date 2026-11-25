/**
 * 客户端侧的会话镜像 —— 纯状态机：输入「本地视图 + 一次服务端回应」，输出「新视图 + 一条判定」。
 * 不碰网络、UI 与磁盘。校验责任在客户端：服务端是匿名的一次性请求，没处存「这台设备读到哪」。
 *
 * 打开替换整窗；重连 opening 保留更早的段、只换尾部；往回翻前插；追新增追加。
 * 事件与窗口直接用协议类型，不另声明一份（同形的两份只能靠逐字段搬运相连）。
 *
 * **水位只有一套口径**：`cursor` 在网上是**含端**的（宿主覆盖到的最后一个 seq），
 * 镜子里把它换成排他的 `frontier`（= `cursor + 1`，下一个期望的 seq）—— 换算只在
 * 进这一层时做一次。两套口径并存时，任何一处 `±1` 漏掉都会让最后一条事件重复或丢失，
 * 而两者都不报错。
 */

/// 需要重置的理由 —— 动作同一个（丢弃位置重取窗口），保留区分是为了界面能如实说明。
enum ResetReason: Equatable {
  /// 事件的 `seq` 跳过了已有内容 —— 中间有事件没拿到。
  case gap
  /// 服务端给的位置比本地还靠前 —— 本地视图不可信。
  case waterMarkWentBack

    /// 这一因是否**否定了本地位置本身** —— 决定「对不上」时保住本地还是清空重来。
    /// 有洞（`.gap`）时本地那段仍然是真的、只是旧：保住它并如实说「更新没接上」。
    /// 水位倒退与位置作废是服务端在说这个位置不作数，屏上内容可能根本不是这段日志 ⇒ 重置。
  var invalidatesLocalContent: Bool {
    switch self {
    case .gap: return false
    case .waterMarkWentBack: return true
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

  /// 下一个期望的 `seq` —— 已有内容的末尾（不含）。`0` 表示「我什么都没有」。
  private(set) var frontier: Int = 0

  /// 当前窗口首条事件的 `seq`。往回翻时把它当 `beforeSeq` 传出去。
  private(set) var windowStart: Int = 0

  /// 窗口之前还有没有更早的记录。为假表示已经到日志开头。
  private(set) var hasMore = false

  /// 打开那一刻日志覆盖到的最后一个 seq（**含端**）。翻页时原样带回，钉住切点 ——
  /// 于是「翻回一页」与「翻页途中又来了新事件」不打架：前者按切点算，后者只动新的那端。
  private(set) var throughSeq = -1

  /// 已落地的视图。按 `seq` 连续，且不含重复。
  private(set) var events: [SessionEvent] = []

  /// 自上次被取走以来，真正进入 `events` 的那些记录。
  ///
  /// 「哪几条是新到的」写入方本来就知道 —— 上层回头对整份窗口做两次 `filter` 去反推，
  /// 代价随历史长度长，而这里只是一次追加。取走即清，所以同一批不会交两次。
  private var pendingFeed: [SessionEvent] = []

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

  /// 窗口自己的内容要成形 —— 同一条校验，`open` 与 `realign` 都过。
  ///
  /// 从前这条比的是「首条 `seq` == 服务端给的窗口起点」；起点现在由首条记录自己给出，
  /// 那条比较成了恒真。留下的是能真出错的那一面：**记录必须按 `seq` 逐条相接**。乱序或
  /// 中间缺一条的一段拼进视图，按 `seq` 渲染会静默错位 —— 错了没人报，肉眼才看得出。
  private static func isSelfConsistent(_ window: SessionWindow) -> Bool {
    var previous: Int?
    for record in window.records {
      if let previous, record.event.seq != previous + 1 { return false }
      previous = record.event.seq
    }
    return true
  }

    /// 打开会话：用最新窗口**替换**整个视图（「什么都没拿过」与「刷新到最新」共用这条路径）。
    /// - Returns: 本次的判定。
  mutating func open(with window: SessionWindow) -> Verdict {
    inFlight = false

    // 窗口的内容不成形（乱序、中间缺条）时，这一屏不能用。
    guard Self.isSelfConsistent(window) else { return .resetRequired(.gap) }

    let inbound = window.events
    frontier = window.cursor + 1
    windowStart = window.start
    throughSeq = window.cursor
    hasMore = window.hasMore
    events = inbound
    pendingFeed = inbound
    return inbound.isEmpty ? .caughtUp : .merged(added: inbound.count)
  }

    /// 重连：新窗口与本地重对齐 —— **本地更早的部分原样保留，只换尾部**。
    /// 按新窗口起点落在哪分三支：更早或相同 ⇒ 整组采用；落在本地内部 ⇒ 保留 `seq < 起点`
  mutating func realign(with window: SessionWindow) -> Verdict {
    inFlight = false

    guard Self.isSelfConsistent(window) else { return .resetRequired(.gap) }

    // 手里什么都没有：这与「打开会话」是同一件事。
    guard !events.isEmpty else { return open(with: window) }

    let inboundFrontier = window.cursor + 1
    if inboundFrontier < frontier {
      return .resetRequired(.waterMarkWentBack)
    }
    if window.start > frontier {
      return .resetRequired(.gap)
    }

    let before = events.count
    if window.start <= windowStart {
      // 新窗口覆盖了本地（起点更早或相同）⇒ 左端跟着它走。
      windowStart = window.start
      hasMore = window.hasMore
      events = window.events
    } else {
      // 保留本地更早的那段；它与新窗口紧邻（新起点落在本地已覆盖的范围里）⇒ 拼起来无缝。
      events = events.filter { $0.seq < window.start } + window.events
    }
    frontier = inboundFrontier
    // 切点跟着这一次打开走：钉的是「宿主此刻覆盖到哪」，不是本地读了多少。
    throughSeq = window.cursor
    // 重连换的是整份视图：交给上层去重（引擎按 order 幂等），比在这里猜「差哪几条」稳。
    pendingFeed = events

    return events.isEmpty ? .caughtUp : .merged(added: events.count - before)
  }

    /// 往回翻：把更早的一段**前插**。末尾不动 —— 往回翻改的是视图起点，不是 `frontier`。
    /// - Returns: 本次的判定。
  mutating func prepend(_ window: SessionWindow) -> Verdict {
    inFlight = false

    // 只接受**紧邻**的一段：这一页的**末尾**必须正好在本地起点下一位。
    //
    // 判据是 `records.last` 而**不是回包的 `cursor`**：`cursor` 是这次读的切点（`throughSeq`，
    // 日志当时覆盖到哪），它大于等于本页末尾 —— 拿它比会把每一次翻页都判成缺口，
    // 而缺口的表现是「中间有事件没拿到」，看上去像另一件事。
    guard Self.endsAt(window, windowStart - 1) else {
      return .resetRequired(.gap)
    }

    events.insert(contentsOf: window.events, at: 0)
    pendingFeed.append(contentsOf: window.events)
    // 起点只由**这一页的首条记录**前移。空页不碰起点 —— 它只可能是「日志到头」那一支。
    if let first = window.records.first { windowStart = first.event.seq }
    hasMore = window.hasMore
    return .merged(added: window.records.count)
  }

  /// 这一页是否正好结束在 `seq` 上。空页只在 `seq == -1`（本地起点已经是 0）时算接上 ——
  /// 那是翻到了日志开头，不是缺口。
  private static func endsAt(_ window: SessionWindow, _ seq: Int) -> Bool {
    if let last = window.records.last { return last.event.seq == seq }
    return seq == -1
  }

    /// 并进一条**实时事件**。
    ///
    /// 顺序是**幂等 → 缺口**：重复（`seq < frontier`）说明它已经在视图里，丢掉；跳号
    /// （`seq > frontier`）说明中间缺了事件，判缺口让上层去重开这条流 —— 两种都「看起来
    /// 只是少一条」，而视图按 `seq` 渲染，静默放过去就是一处不会报错的错位。
    ///
    /// **不碰 `inFlight`**：事件不是对某次请求的回应，翻页在途时它照常到达。
    mutating func append(_ event: SessionEvent) -> Verdict {
        if event.seq < frontier { return .caughtUp }
        if event.seq > frontier { return .resetRequired(.gap) }
        events.append(event)
        pendingFeed.append(event)
        frontier = event.seq + 1
        return .merged(added: 1)
    }

    /// 丢弃位置与视图。由调用方在收到 `resetRequired` 后调用 —— 重置是用户看得见的事件。
  mutating func reset() {
    frontier = 0
    windowStart = 0
    hasMore = false
    throughSeq = -1
    events = []
    pendingFeed = []
    inFlight = false
  }

  /// 把一批记录重新排进下一批。
  ///
  /// 上层「先扣下、之后作废」的定稿要靠它回来：`takeFeed` 取走即清，扣下的那次已经
  /// 消费过那一批 —— 没有这一步，被作废的记录就永久停在 `events` 里没人再看一眼。
  mutating func requeue(_ events: [SessionEvent]) {
    pendingFeed.append(contentsOf: events)
  }

  /// 取走这一批新增。返回空表示「没有新东西」—— 上层据此提前返回，不再自己比对。
  mutating func takeFeed() -> [SessionEvent] {
    defer { pendingFeed = [] }
    return pendingFeed
  }
}

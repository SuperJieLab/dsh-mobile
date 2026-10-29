import Foundation

/**
 * 订阅方对一帧的答复：这条流接下来怎么办，以及它是否从此刻建成。
 * 两个值都由订阅方算（见 `StreamReading`），流表只照着做 —— 于是它不需要认识帧类型的取值、
 */
struct StreamReply: Equatable {

    /// 这一帧是否意味着「这条流从此刻建成」。
    /// 由流表在**收到每一帧时**读一次，而不是等订阅方主动通报 —— 漏调的写法没有任何信号。
    let establishes: Bool

    /// 这条流接下来该怎么办。
    let next: StreamNext

    init(establishes: Bool = false, next: StreamNext = .keep) {
        self.establishes = establishes
        self.next = next
    }
}

/// 一帧之后，连接层要做的动作。
/// **四个值全部只作用于这一条流。** 连接级重连（关 socket、退避、重建）不在这里。
enum StreamNext: Equatable {
    /// 什么都不做。
    case keep
    /// 这条流还在，但不在工作了：**立刻**在同一条连接上换号重开（服务端正常收尾）。
    case reopen
    /// 这条流被拒，但值得再试：**按它自己的退避**换号重开。连接与别的流不动。
    case retry
    /// 终态：再开也是同一个结果，收起这一条流。**连接不动**，别的流照旧。
    case stop
}

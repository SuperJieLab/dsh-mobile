import Foundation

/**
 * 订阅方对一帧的答复：这条流接下来怎么办，以及它是否从此刻建成。
 *
 * 两个值都由订阅方算（见 `StreamReading`），连接层只照着做 —— 于是它不需要认识帧类型的取值、
 * 不知道哪个错误码是终态，也不判断「打开帧到了没有」。
 */
struct StreamReply: Equatable {

    /// 这一帧是否意味着「这条流从此刻建成」。
    ///
    /// 由连接层在**收到每一帧时**读一次，而不是等订阅方主动通报：漏调的写法没有任何信号，
    /// 心跳永不激活、退避永不归零，表现为每 45 秒静默断一次而内容照常显示。
    let establishes: Bool

    /// 这条流接下来该怎么办。
    let next: StreamNext

    init(establishes: Bool = false, next: StreamNext = .keep) {
        self.establishes = establishes
        self.next = next
    }
}

/// 一帧之后，连接层要做的动作。
enum StreamNext: Equatable {
    /// 什么都不做。
    case keep
    /// 这条流还在，但不在工作了：在同一条连接上重开一次（服务端正常收尾）。
    case reopen
    /// 这条流死了但不该停：关连接、退避重连。
    case reconnect
    /// 终态：再连也是同一个结果，停掉整个订阅循环。
    case stop
}

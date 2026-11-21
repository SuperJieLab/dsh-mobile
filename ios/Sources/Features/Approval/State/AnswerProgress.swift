/**
 * 一条应答的三种进展 —— **审批与提问共用这一份定义**。
 *
 * 三件事必须一致：`sending` / `unknown` / `refused` 各自的文案、被拒时卡留不留、
 * 以及「未知不重发」。两条链路各写一份枚举，这些规则就会在两处漂 —— 而漂了不会编译失败。
 */
enum AnswerProgress: Equatable {
    /// 请求已发出、回包还没到。
    case sending
    /// 结果未知 —— 卡留着，等上游结算。两种来路：**发出去了但传输失败**，
    /// 以及**根本没发**（这条流还没就绪，没有归属的键）。两者对用户说的是同一件事：
    /// 现在不知道结果，别按第二次。
    case unknown
    /// 服务端拒了这次投递，附人话说明 —— 那个问题仍挂在网关的暂存里。
    case refused(String)
}

/// 一张卡上某一问的选择：勾了哪些、以及自定义文本。纯值 —— 视图与 Store 都只读它。
struct QuestionSelection: Equatable {
    var selected: Set<String> = []
    var custom: String = ""
}

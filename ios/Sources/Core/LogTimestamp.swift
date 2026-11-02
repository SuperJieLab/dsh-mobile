/**
 * 日志行的时间戳 —— **本机时间 + 显式偏移**，如 `2026-11-02T14:58:12.188+08:00`。
 *
 * 为什么不用 UTC：这份日志唯一的读者是人，且他正对着自己机器的时钟看。UTC 会让他每次
 * 心算减八小时，而那不是排障时该花的心力。
 *
 * 为什么不能只写本地时间：**不带偏移的本地时间有歧义** —— 同一份日志里「14:58」到底是
 * 本机还是 UTC 看不出来，跨时区、或跨一次夏令时边界，那批行就没法还原成时刻。
 * 带偏移则两件事同时成立：一眼读得懂，且永远可换算。
 *
 * 手写而不是用 `ISO8601DateFormatter`：那一类的默认时区是 GMT（这正是一条容易被忽略的
 * 静默来源），而且要按需重建才安全。这里按日历取分量、按 `secondsFromGMT(for:)` 取偏移 ——
 * 夏令时在那一刻的偏移由系统回答，不需要我们判断。
 *
 * 与网关侧（`mac-gateway/src/timestamp.ts`）同一组样本，两份实现靠字面量对齐。
 */
import Foundation

enum LogTimestamp {

    /// 一个时刻写成一行日志的抬头。
    ///
    /// @param date - 时刻。
    /// @param timeZone - 用它读墙上时间与偏移。默认本机。
    static func string(from date: Date, in timeZone: TimeZone = .current) -> String {
        // 毫秒与「秒」都从同一个取整后的总数里分出来：分开算会在 .9995 这类边界上一毫秒地错开。
        let totalMillis = Int((date.timeIntervalSince1970 * 1000).rounded())
        let wholeSeconds = totalMillis / 1000
        let millis = totalMillis - wholeSeconds * 1000

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: Date(timeIntervalSince1970: TimeInterval(wholeSeconds)))

        let dateText = "\(pad(parts.year ?? 0, 4))-\(pad(parts.month ?? 1))-\(pad(parts.day ?? 1))"
        let timeText = "\(pad(parts.hour ?? 0)):\(pad(parts.minute ?? 0)):\(pad(parts.second ?? 0))"
        // 偏移按**那一刻**问，不按此刻：跨夏令时边界的行各带各的偏移，每一行都自足。
        let offset = timeZone.secondsFromGMT(for: date)
        return "\(dateText)T\(timeText).\(pad(millis, 3))\(zoneText(offset))"
    }

    private static func zoneText(_ offsetSeconds: Int) -> String {
        guard offsetSeconds != 0 else { return "Z" }
        let sign = offsetSeconds < 0 ? "-" : "+"
        let magnitude = abs(offsetSeconds)
        return "\(sign)\(pad(magnitude / 3600)):\(pad((magnitude % 3600) / 60))"
    }

    /// 左补零到 `width` 位。`String.padding(toLength:)` 是**右**补且会截断，方向不对。
    private static func pad(_ value: Int, _ width: Int = 2) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}

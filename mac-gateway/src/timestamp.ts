/**
 * 日志行的时间戳格式 —— **两端共用一份判据（同一组样本），实现各一份**。
 *
 * 形状：`2026-11-02T14:58:12.188+08:00`（本机时间 + 显式偏移），偏移为 0 时写 `Z`。
 *
 * 为什么不用 UTC：这份日志唯一的读者是人，且他正对着自己机器的时钟看。UTC 会让他每次
 * 心算减八小时，而那不是排障时该花的心力。
 *
 * 为什么不能只写本地时间：**不带偏移的本地时间有歧义** —— 同一份日志里「14:58」到底是
 * 本机还是 UTC 看不出来，跨时区、或跨一次夏令时边界，那批行就没法还原成时刻。
 * 带偏移则两件事同时成立：一眼读得懂，且永远可换算。
 *
 * 住在独立文件而不是 `log.ts`：`log.ts` 重导出 `perf.ts` 的埋点出口，而 `perf.ts` 也要用
 * 这个函数 —— 放在 `log.ts` 里会成环。这里是叶子，谁都能依赖。
 */

/**
 * 一行的时间戳。
 *
 * @param now - 时刻。
 * @param offsetMinutes - 本机相对 UTC 的分钟数（东八区为 480）。默认从 `now` 的时区取。
 */
export function logTimestamp(now: Date, offsetMinutes: number = -now.getTimezoneOffset()): string {
  const local = new Date(now.getTime() + offsetMinutes * 60_000)
  const date = `${pad(local.getUTCFullYear(), 4)}-${pad(local.getUTCMonth() + 1)}-${pad(local.getUTCDate())}`
  const time = `${pad(local.getUTCHours())}:${pad(local.getUTCMinutes())}:${pad(local.getUTCSeconds())}`
  const zone = offsetMinutes === 0 ? 'Z' : `${sign(offsetMinutes)}${pad(hoursOf(offsetMinutes))}:${pad(minutesOf(offsetMinutes))}`
  return `${date}T${time}.${pad(local.getUTCMilliseconds(), 3)}${zone}`
}

/** 偏移的极性。0 单独处理（走 `Z`），所以这里只剩两态。 */
function sign(offsetMinutes: number): string {
  return offsetMinutes < 0 ? '-' : '+'
}

function hoursOf(offsetMinutes: number): number {
  return Math.trunc(Math.abs(offsetMinutes) / 60)
}

function minutesOf(offsetMinutes: number): number {
  return Math.abs(offsetMinutes) % 60
}

function pad(value: number, width = 2): string {
  return String(value).padStart(width, '0')
}

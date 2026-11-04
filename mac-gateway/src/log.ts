// 唯一日志出口：本机时间（带显式偏移）+ [dsh] + [级别][模块]；形状定义在 `timestamp.ts`，两端一致。
// [dsh] 是全局过滤标签（两端一致）：混在别的进程/系统输出里时按它 grep 只留我们的行。
// debug 级默认静默，DSH_LOG_DEBUG=1 打开；warn/error 走 stderr，其余走 stdout。
import { AsyncLocalStorage } from 'node:async_hooks';
import { randomUUID } from 'node:crypto';

import { logTimestamp } from './timestamp.ts';

export type LogLevel = "debug" | "info" | "warn" | "error";

// 模块标签集中在此登记，调用点不允许手写散字符串。
export const LogModule = {
  main: "main",
  http: "http",
  ws: "ws",
  relay: "relay",
  forwarded: "forwarded",
  faces: "faces",
  model: "model",
  command: "command",
  // 权限预设：目录读取与「切一档」那次命令调用。与 `command` 分开是因为它失败时
  // 手机上的落点不同（那一格显示旧值），排障时要知道是目录读不出还是切换被拒。
  permission: "permission",
  usage: "usage",
  // 工作空间的写链路：问系统要根、建目录、注册、解注册。与 `faces` 分开是因为
  // 这条链有一步在进程之外（osascript），排障时要能把它单独拎出来看。
  workspace: "workspace",
} as const;

/**
 * 结构化字段：动态值走这里，正文只写固定短语。
 *
 * 为什么要有它：正文里插值的行只能正则取，于是「按 op 统计失败率」「按工作空间看耗时」
 * 做不到 —— 而那是日志存在的第二个理由。字段化之后同一个 key 在任何模块里都是同一个意思。
 *
 * 值只收标量：日志是给人读的，嵌一个对象进去只会让 grep 变成猜。
 */
export type LogFields = Record<string, string | number | boolean | undefined>;

export type Logger = Record<LogLevel, (message: string, fields?: LogFields) => void>;

/**
 * 把字段拼成 ` key=value key2=value2`，按 key 排序。
 *
 * 排序不是洁癖：同一行日志在不同次跑里字段顺序不同的话，diff 与「这行变了没」都要重新看。
 * 含空格或等号的值用 JSON 引号包起来 —— 否则 `msg=a b` 会让 grep 的人以为有两个字段。
 */
export function formatLogFields(fields?: LogFields): string {
  if (fields === undefined) return "";
  const keys = Object.keys(fields)
    .filter((key) => fields[key] !== undefined)
    .sort();
  if (keys.length === 0) return "";
  const parts = keys.map((key) => {
    const raw = String(fields[key]);
    const needsQuote = /[\s="]/.test(raw);
    return `${key}=${needsQuote ? JSON.stringify(raw) : raw}`;
  });
  return ` ${parts.join(" ")}`;
}

/**
 * 行去哪。默认 stdout / stderr —— 生产上唯一的去向。
 *
 * 可替换只有测试会做（与 `perf.ts` 的 `setPerfSink` 同一个手法）：有一条判据是
 * 「osascript 超时之后日志里读得到那一句」，而那句话的价值恰恰在于**别的失败说不出它** ——
 * 不能捕获就无从断言。
 */
let sink: (level: LogLevel, module: string, line: string) => void = (level, _module, line) => {
  if (level === "warn" || level === "error") console.error(line);
  else console.log(line);
};

/** 测试后门：替换行的去向。返回上一个，便于用完还原。 */
export function setLogSink(next: typeof sink): typeof sink {
  const previous = sink;
  sink = next;
  return previous;
}

export function createLogger(module: string): Logger {
  const debugEnabled = process.env.DSH_LOG_DEBUG === "1";
  const emit = (level: LogLevel) => (message: string, fields?: LogFields): void => {
    if (level === "debug" && !debugEnabled) return;
    const tag = `${logTimestamp(new Date())} [dsh][${level}][${module}]`;
    // 请求标记只在有请求上下文时出现。放在模块标签之后、正文之前：按它 grep 时
    // 两种行都能命中同一条正则。
    const marker = currentRequestId() === undefined ? "" : ` [req=${currentRequestId()}]`;
    sink(level, module, `${tag}${marker} ${message}${formatLogFields(fields)}`);
  };
  return { debug: emit("debug"), info: emit("info"), warn: emit("warn"), error: emit("error") };
}

/**
 * 一次请求的关联标记。
 *
 * 为什么需要它：网关同时服务多个请求，日志交错写在一起。没有标记时，「这一次工作空间
 * 创建为什么失败」要靠时间接近去猜 —— 并发两件事就分不开。有了它，同一个 id 的若干行
 * 就是同一次请求，且客户端那侧记的是同一个 id。
 *
 * 用 `AsyncLocalStorage` 而不是显式传参：`handle` 往下有五六层（端口、适配器、控制器），
 * 为传一个日志标记而改每一层的签名，代价远大于收益，而且每一处都可能漏传。
 *
 * 没设上下文时 `currentRequestId()` 是 `undefined`，行格式与从前完全一致 —— 启动期、
 * 后台任务、测试里的日志都不会多出一个空标记。
 */
const requestScope = new AsyncLocalStorage<{ id: string }>();

/** 当前异步上下文里的请求 id，没有则 `undefined`。 */
export function currentRequestId(): string | undefined {
  return requestScope.getStore()?.id;
}

/**
 * 在一个请求标记下执行。`run` 返回什么就返回什么。
 *
 * @param id - 客户端给的关联 id（缺失时调用方自己铸一个，见 `remote/http.ts`）。
 * @param run - 这次请求的全部工作。
 */
export function runWithRequestId<T>(id: string, run: () => T): T {
  return requestScope.run({ id }, run);
}

/** 铸一个短 id。只用于「客户端没带」的情况 —— 正常情况下标记由客户端给，两端才对得上。 */
export function mintRequestId(): string {
  return randomUUID().slice(0, 8);
}

// 时间戳的形状在 `timestamp.ts`（两端各一份实现、同一组样本）；这里只是唯一的出口。
export { logTimestamp } from './timestamp.ts';
// 性能记录通道（R8 期1）：调用面统一走本文件导出，物理实现在 perf.ts ——
// 同标签、同门控、同 stderr 的一支。埋点调用点因此只 import log.ts 一个出口。
export {
  perfNow,
  perfRecord,
  setPerfSink,
  startResourceSampler,
  type PerfRecord,
} from './perf.ts';

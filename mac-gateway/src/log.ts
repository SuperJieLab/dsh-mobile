// 唯一日志出口：ISO8601 UTC 毫秒时间戳 + [dsh] + [级别][模块]；格式只此处定义，两端一致。
// [dsh] 是全局过滤标签（两端一致）：混在别的进程/系统输出里时按它 grep 只留我们的行。
// debug 级默认静默，DSH_LOG_DEBUG=1 打开；warn/error 走 stderr，其余走 stdout。
export type LogLevel = "debug" | "info" | "warn" | "error";

// 模块标签集中在此登记，调用点不允许手写散字符串。
export const LogModule = {
  main: "main",
  http: "http",
  ws: "ws",
  relay: "relay",
  faces: "faces",
  model: "model",
  command: "command",
  usage: "usage",
} as const;

export type Logger = Record<LogLevel, (message: string) => void>;

export function createLogger(module: string): Logger {
  const debugEnabled = process.env.DSH_LOG_DEBUG === "1";
  const emit = (level: LogLevel) => (message: string): void => {
    if (level === "debug" && !debugEnabled) return;
    const line = `${new Date().toISOString()} [dsh][${level}][${module}] ${message}`;
    if (level === "warn" || level === "error") console.error(line);
    else console.log(line);
  };
  return { debug: emit("debug"), info: emit("info"), warn: emit("warn"), error: emit("error") };
}

// 性能记录通道（R8 期1）：调用面统一走本文件导出，物理实现在 perf.ts ——
// 同标签、同门控、同 stderr 的一支。埋点调用点因此只 import log.ts 一个出口。
export {
  perfEnabled,
  perfLine,
  perfNow,
  perfRecord,
  resourceRecord,
  setPerfSink,
  startResourceSampler,
  type PerfRecord,
  type PerfSeg,
  type ResourceSample,
} from './perf.ts';

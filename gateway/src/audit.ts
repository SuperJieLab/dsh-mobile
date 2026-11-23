// 审计：谁在什么时候做了什么写操作。
//
// 与日志的区别不是「重要程度」，是**记什么**：日志记过程（重试、状态迁移、中途失败），
// 审计记结果（一次写 op 恰好一条，成功或被拒绝）。所以保留策略也不同 —— 日志轮转会丢掉
// 前半，审计只按月切文件、从不丢弃。
//
// 增长量级：一天几十到两百条，一年几 MB。切分不是为了控体积，是因为「按时间倒序取最近
// N 条」这个读取面按月翻最省事 —— 而且一年的 12 个文件正好回答「这个月谁动过什么」。
import { appendFileSync, mkdirSync, readFileSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import { formatLogFields } from './log.ts'
import { requestContainerOf } from './wire/fields.ts'
import type { RemoteResult } from './wire/unary.ts';
import { logTimestamp } from './timestamp.ts';


// 写不写审计由端点表的 `write` 标记决定（`protocol/unary-endpoints.ts`）。
// 这里曾经存过一份 `WRITE_OPS` 清单，与那个标记互为副本；信封统一之后只有一处判定，
// 副本就成了「忘了同步也不会红」的第二真源 —— 删掉，判据在
// `tests/remote/http-auth.test.ts`（每个写端点各记一条）。

/** 一条审计记录。 */
export interface AuditEntry {
  /** 可读时间戳（带偏移）。行首也是它 —— `recent()` 解析回来直接用于显示。 */
  at: string;
  op: string;
  /** 被操作的对象：会话 / 工作空间 / 审批的 id。`-` 意为这次请求没带。 */
  target: string;
  result: 'ok' | 'refused';
  /** 拒绝码，只在 `refused` 时出现。 */
  code?: string;
  /** 请求标记，与日志里的 `[req=…]` 同值 —— 拿它去 grep 就是那一刻的现场。 */
  request?: string;
}

/**
 * 一条记录拼成一行。
 *
 * 字段值与日志同一套拼法（按 key 排序、含空格加引号），但审计这里**多一条约束**：
 * 值不含空格。`op` / `result` / `code` 是枚举，`target` 是 id —— 它们本来就没有空格，
 * 所以解析可以按空格切而不用处理引号。加一个含空格的 target 会解析错，因此
 * {@link parseAuditEntry} 遇到拆不出的行会返回 `undefined` 而不是猜。
 */
export function formatAuditEntry(entry: AuditEntry): string {
  const fields = {
    op: entry.op,
    target: entry.target,
    result: entry.result,
    ...(entry.code === undefined ? {} : { code: entry.code }),
    ...(entry.request === undefined ? {} : { req: entry.request }),
  };
  return `${entry.at} [audit]${formatLogFields(fields)}`;
}

const LINE_PATTERN = /^(\S+) \[audit\] (.+)$/;

/** 解析回来。认不出的行返回 `undefined` —— 半条记录读成一条比读不出来更坏。 */
export function parseAuditEntry(line: string): AuditEntry | undefined {
  const matched = LINE_PATTERN.exec(line);
  if (matched === null) return undefined;

  const fields: Record<string, string> = {};
  for (const part of matched[2].split(' ')) {
    const equals = part.indexOf('=');
    if (equals <= 0) continue;
    fields[part.slice(0, equals)] = part.slice(equals + 1);
  }
  if (fields.op === undefined || fields.target === undefined) return undefined;

  return {
    at: matched[1],
    op: fields.op,
    target: fields.target,
    result: fields.result === 'ok' ? 'ok' : 'refused',
    ...(fields.code === undefined ? {} : { code: fields.code }),
    ...(fields.req === undefined ? {} : { request: fields.req }),
  };
}

/** 时间戳属于哪个月的文件。`2026-11-04T…` → `audit-2026-11.log`。 */
export function fileNameOf(at: string): string {
  return `audit-${at.slice(0, 7)}.log`;
}

const FILE_PATTERN = /^audit-\d{4}-\d{2}\.log$/;

/**
 * 审计文件的落点与读取。
 *
 * 写入**从不抛错**（与日志同纪律）：记不下来不该让一次写操作失败。代价是「这次没记上」
 * 不会被当场发现 —— 但反过来，让删工作空间因为磁盘满而失败是更坏的交换。
 */
export class AuditLog {
  private readonly directory: string;

  constructor(directory: string) {
    this.directory = directory;
  }

  /**
   * 追加一条。时间戳由这里补，调用方不必知道格式。
   *
   * @param fields - 除时间戳外的全部字段。
   * @param at - 时刻；可注入以保测试确定性（与 `invokeEndpoint` 的 `now` 同一个理由）。
   */
  append(fields: Omit<AuditEntry, 'at'>, at: Date = new Date()): void {
    const entry: AuditEntry = { at: logTimestamp(at), ...fields };
    try {
      mkdirSync(this.directory, { recursive: true });
      appendFileSync(join(this.directory, fileNameOf(entry.at)), `${formatAuditEntry(entry)}\n`);
    } catch {
      // 磁盘满、目录被外部删掉：这一次没记上，下一次请求会再试。
    }
  }

  /** 最近 `limit` 条，**按时间倒序**。 */
  recent(limit: number): AuditEntry[] {
    if (limit <= 0) return [];

    let files: string[];
    try {
      // 文件名是 `audit-YYYY-MM.log`，字典序即时间序，所以从后往前读就是倒序。
      files = readdirSync(this.directory)
        .filter((name) => FILE_PATTERN.test(name))
        .sort()
        .reverse();
    } catch {
      return [];
    }

    const out: AuditEntry[] = [];
    for (const file of files) {
      let lines: string[];
      try {
        lines = readFileSync(join(this.directory, file), 'utf8').split('\n');
      } catch {
        continue;
      }
      for (let index = lines.length - 1; index >= 0 && out.length < limit; index -= 1) {
        const entry = parseAuditEntry(lines[index]);
        if (entry !== undefined) out.push(entry);
      }
      if (out.length >= limit) break;
    }
    return out;
  }
}

/**
 * 默认落点：`~/.dsh/dsh-mobile/audit/`。
 *
 * 与 `credentials.json` 同目录 —— 那是网关的数据根，备份与迁移时一并带走。
 */
export function defaultAuditDirectory(): string {
  return join(homedir(), '.dsh', 'dsh-mobile', 'audit');
}

/**
 * 把一次写 op 折成一条审计记录。
 *
 * **结果从应答取，目标从请求取**。应答里不一定有目标（`workspace-delete` 的成功应答是
 * 空对象），而「想动谁」在请求里总有；反过来请求里没有结果 —— 那正是审计要记的东西。
 *
 * 住在 `audit.ts` 而不是 `protocol/rpc.ts`：协议层只判消息、不碰副作用，那条有判据守着
 * （`tests/structure.test.ts` 的「protocol/ only reaches into wire/ and ports/」）。
 * 审计是传输层的事，与它同处的是请求标记、日志 —— 不是协议判定。
 */
export function auditEntryOf(
  op: string,
  message: Record<string, unknown>,
  // 只取「成不成」与拒绝码两格：`RemoteResult` 的其余格（`value` / `details`）
  // 与审计无关 —— 审计回答「谁改了什么、成没成」，不复制应答内容。
  answer: RemoteResult,
  requestId?: string,
): Omit<AuditEntry, 'at'> {
  const base = { op, target: auditTargetOf(op, message), request: requestId };
  return answer.ok
    ? { ...base, result: 'ok' }
    // 拒绝时 `error` 一定在（类型上由判别联合保证），这里不必再兜。
    : { ...base, result: 'refused', code: answer.error.code };
}

/**
 * 一次写 op 作用在什么上。
 *
 * 拿不到时给 `-` 而不是留空：空值会让「这次请求没带目标」与「解析坏了」看起来一样，
 * 而它们要查的地方不同。
 */
function auditTargetOf(op: string, message: Record<string, unknown>): string {
  // 三条写 op 的宿主签名都收一个 `request` 对象，线上因此多一层容器；
  // 目标在那层里面。容器缺席时 `{}` —— 于是目标记成 `-`，与「没带目标」同形。
  const request = requestContainerOf(message) ?? {};
  switch (op) {
    case 'session-prompt':
      return identifierOf(request.sessionId);
    case 'model-select':
      return identifierOf(request.sessionId);
    case 'command-execute':
      // 命令域在线上叫 `agentId`（宿主的参数名）；值与会话 id 同。
      return identifierOf(message.agentId);
    case 'events-result':
      // `$events/result` 的参数是平铺的三键（上游的形），目标就是那条挂起项。
      return identifierOf(message.eventId);
    case 'workspace-create':
      // 工作空间由路径标识（F3 第 4 期起没有名字这一格）。
      return identifierOf(request.path);
    case 'workspace-delete':
      return identifierOf(request.workspaceId);
    case 'session-create':
      // 不带 `workspaceId` 意为「交给宿主当前目录」：不是缺失，是一个明确的「未指定」。
      return request.workspaceId === undefined ? '-' : identifierOf(request.workspaceId);
    default:
      return '-';
  }
}

/** 审计字段值不许含空格（见 {@link formatAuditEntry}），所以这里只收标识符。 */
function identifierOf(value: unknown): string {
  return typeof value === 'string' && value !== '' ? value : '-';
}

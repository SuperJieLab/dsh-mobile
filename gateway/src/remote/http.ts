/**
 * 面向手机的 HTTP 传输：路由一条请求、执行传输层守卫、把守身份 ——
 * socket 层调用方欠协议的一切，只要不是协议本身。
 *
 * 状态码不是协议 —— 结果由信封携带，协议层拒绝也是 HTTP 200。`/rpc`
 * 承载协议消息；其余只帮人区分「监听器活着」与「什么都没在听」。
 */
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { createServer } from 'node:http'
import { failure, handle, type Limits } from '../protocol/rpc.ts'
import { handleAuthOp } from '../protocol/auth-ops.ts'
import { PROTOCOL_VERSION } from '../wire/rpc.ts'
import type { SessionPort } from '../ports/session.ts'
import type { CommandPort } from '../ports/command.ts'
import type { PermissionPort } from '../ports/permission.ts'
import type { WritePort } from '../ports/write.ts'
import type { ModelPort } from '../ports/model.ts'
import type { WorkspacePort } from '../ports/workspace.ts'
import { auditEntryOf, isWriteOp, type AuditLog } from '../audit.ts'
import type { Metrics } from '../metrics.ts'
import { CredentialVault } from './credentials.ts'
import type { PairResponse, RefreshResponse } from '../wire/auth.ts'
import { createLogger, LogModule, currentRequestId, mintRequestId, runWithRequestId } from '../log.ts'

const log = createLogger(LogModule.http)

/** 请求体上限 —— 传输层守卫，不是协议规则：端口 LAN 可达，无界读是内存
 * 耗尽的把手。1 MiB 远高于任何 v2 请求。 */
const MAX_BODY_BYTES = 1_048_576

/**
 * 拒绝时**不**留痕的 op —— 判定方向取「默认留痕」，这张表只装例外。
 *
 * 三条都是纯读 op：它们的失败在手机上有明确落点（列表的失败横幅、详情的失败态），
 * 服务端再记一条只是把噪声翻倍。方向不能反过来列一张「要留痕的 op」名单 ——
 * 白名单漏掉一个新 op 是**静默**的（那个 op 失败之后无处归因），而黑名单漏掉只是多一条日志。
 *
 * 表里的名字必须是 `handle` 真的认得的 op：改名或删 op 之后留下的死条目意味着这一条
 * 既没有日志、也没人知道它本该静默。
 */
export const SILENT_REFUSALS: ReadonlySet<string> = new Set(['list-sessions', 'snapshot', 'page'])

/**
 * 这次请求的关联 id：客户端给的那个，没有就现铸一个。
 *
 * 客户端给的才有跨端价值 —— 它同一侧记的也是这个 id。现铸的那份只保证网关内部这一次的
 * 若干行能归到一起，与客户端对不上；所以「客户端没带」本身是可诊断的（看 id 是不是 8 位
 * 随机串就知道），而不是悄悄退回时间对账。
 *
 * 头名与 iOS 侧 `RpcTrace.headerName` 必须一致。
 */
function requestIdOf(headers: IncomingMessage['headers']): string {
  const given = headers['x-dsh-request-id']
  const text = Array.isArray(given) ? given[0] : given
  return typeof text === 'string' && text !== '' ? text : mintRequestId()
}

/** 监听器应答一条请求所需的依赖。 */
export interface RpcListenerDeps {
  sessionPort: SessionPort
  limits: Limits
  vault: CredentialVault
  writePort: WritePort
  modelPort: ModelPort | undefined
  commandPort: CommandPort | undefined
  /** 权限预设的读与切换；只读装配可以不给，那时两条 op 都拒答。 */
  permissionPort: PermissionPort | undefined
  /** 列表分组的来源；只读装配可以不给，那时应答里没有组清单。 */
  workspacePort: WorkspacePort | undefined
  /** 写操作的审计落点；不给 = 不记（只读装配与判据不需要它）。 */
  auditLog: AuditLog | undefined
  /** 指标表；不给 = `/metrics` 返回空（判据用最小装配时）。 */
  metrics?: Metrics
}

/**
 * 构建插件自己的 HTTP 监听器：一个 server，`POST /rpc` 走单向调用，
 * 流升级共享端口（与其他请求同一闸门 —— 无有效 access token，就没有 101；
 * 见 remote/server.ts）。
 */
export function createRpcListener(deps: RpcListenerDeps): Server {
  // `respond` 从不 reject；此处抛出会成为未处理的 rejection。
  return createServer((request, response) => {
    void respond(request, response, deps)
  })
}

/** 路由一条请求。 */
async function respond(
  request: IncomingMessage,
  response: ServerResponse,
  deps: RpcListenerDeps,
): Promise<void> {
  const path = new URL(request.url ?? '/', 'http://gateway').pathname

  if (path === '/metrics') {
    // 匿名，与 `/` 同级：能连到这个端口就能读存活探测，而指标里没有凭据 ——
    // op 名是协议公开的词汇。加鉴权会让「随时 curl 一下」变麻烦，而那正是它存在的理由。
    // content-type 带 version=0.0.4 是 Prometheus 的文本格式约定。
    response.writeHead(200, { 'content-type': 'text/plain; version=0.0.4; charset=utf-8' })
    response.end(deps.metrics?.render() ?? '')
    return
  }

  if (path !== '/rpc') {
    // 存活探测，以及任何未知路径的回答。纯传输层：不涉协议消息，
    // 也不涉信封。版本号取常量而非硬编码 —— 它能升，这句话不能跟着说谎。
    response.writeHead(path === '/' ? 200 : 404, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(path === '/'
      ? `dsh-mobile-gateway alive — protocol v${PROTOCOL_VERSION}, POST /rpc for the protocol\n`
      : 'not found\n')
    return
  }

  if (request.method !== 'POST') {
    response.writeHead(405, { 'content-type': 'text/plain; charset=utf-8', allow: 'POST' })
    response.end('use POST /rpc\n')
    return
  }

  // 整条链路都在这个作用域里：读体、鉴权、分派、拒绝时的留痕。任何一步的行都属于
  // 同一次请求，所以标记要在这里设、而不是等到 `handle` 那一步 —— 否则「401 被拒」
  // 那种最需要归因的行反而不带标记。
  await runWithRequestId(requestIdOf(request.headers), () => respondInScope(request, response, deps))
}

/** `respond` 的 `/rpc` POST 分支，已带请求标记。 */
async function respondInScope(
  request: IncomingMessage,
  response: ServerResponse,
  deps: RpcListenerDeps,
): Promise<void> {

  let body: string
  try {
    body = await readBody(request)
  } catch (error) {
    // 根本不是消息，按传输失败拒绝，而不是用带着无意义码的协议信封作答。
    response.writeHead(error instanceof TooLargeError ? 413 : 400, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`malformed request: ${String(error)}\n`)
    return
  }

  let message: unknown
  try {
    message = JSON.parse(body)
  } catch (error) {
    response.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`malformed request: ${String(error)}\n`)
    return
  }

  // 身份：auth op 的凭据放在体内，其余 op 都需要有效的 access token；
  // 被拒时以 HTTP 401 附协议信封。
  const op = (message as { op?: unknown } | null)?.op
  if (op === 'pair' || op === 'refresh') {
    const answer = handleAuthOp(op, message, deps.vault)
    // 留痕在这里而不是判定里：判定是纯的，日志是传输层的事。
    logAuthOp(op, answer)
    // 「没成」就是 401 —— 这一层不需要再判一次为什么失败。
    response.writeHead(answer.ok ? 200 : 401, { 'content-type': 'application/json; charset=utf-8' })
    response.end(`${JSON.stringify(answer)}\n`)
    return
  }

  if (!deps.vault.authenticate(request.headers.authorization)) {
    // info 而非 warn：票过期后的这次 401 是续期编排的正常一环，客户端拿到 401 会
    // 静默换票重试；warn 留给 refresh 本身被拒（关系被掐）。
    log.info('op refused: no live access token', { op: String(op) })
    response.writeHead(401, { 'content-type': 'application/json; charset=utf-8' })
    response.end(`${JSON.stringify(failure('unauthenticated', 'missing or expired access token — pair first, then refresh'))}\n`)
    return
  }

  const answer = await handle(message, { session: deps.sessionPort, write: deps.writePort, model: deps.modelPort, command: deps.commandPort, workspace: deps.workspacePort, permission: deps.permissionPort }, Date.now, deps.limits)
  // 每个 op 一次计数，成败各一。这里记的是**所有** op —— 审计只记写 op，
  // 而「哪个读 op 在失败」同样要能回答。
  if (typeof op === 'string') {
    deps.metrics?.count('dsh_rpc_requests_total', {
      op,
      result: answer.ok ? 'ok' : 'refused',
    })
  }
  // 写 op 一条对应一条，记**结果**不记意图。读 op 不记 —— 审计回答「谁改了什么」，
  // 而读不改变任何东西。
  if (typeof op === 'string' && isWriteOp(op)) {
    deps.auditLog?.append(
      auditEntryOf(op, message as Record<string, unknown>, answer, currentRequestId()),
    )
  }
  // 拒绝在服务端留证据：手机对一次失败的写 op 只显示一行状态，对一次失败的读 op
  // 只在它自己那一屏留个提示 —— 归因要回到网关日志。静默的例外见 {@link SILENT_REFUSALS}。
  if (!answer.ok && typeof op === 'string' && !SILENT_REFUSALS.has(op)) {
    log.error('op refused', { op: String(op), error: JSON.stringify(answer.error) })
  }
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
  response.end(`${JSON.stringify(answer)}\n`)
}

/**
 * 身份链路上的两条留痕 —— 判定在 `protocol/auth-ops.ts`，这里只负责说给人听。
 *
 * 三条各有各的读者：配对成功是「关系建立了」的锚点（之后列表还 401 就先看它）；
 * 配对失败要能区分「码错了」与「码过期了」；续期被拒是服务端**掐断关系**的唯一时刻。
 */
function logAuthOp(
  op: 'pair' | 'refresh',
  answer: PairResponse | RefreshResponse,
): void {
  if (op === 'pair') {
    if (answer.ok) {
      log.info('pair accepted — device relationship established')
    } else {
      log.warn('pair refused', { error: answer.error?.message ?? 'unknown' })
    }
    return
  }
  if (!answer.ok) {
    log.warn('refresh refused: unknown device token — relationship severed')
  }
}

/** 请求体超过 {@link MAX_BODY_BYTES} 时抛出。 */
class TooLargeError extends Error {
  constructor() {
    super(`body exceeds ${MAX_BODY_BYTES} bytes`)
    this.name = 'TooLargeError'
  }
}

/**
 * 读请求体，拒绝超出上限的增长。限制在收集过程中执行，而非之后，
 * 超限的请求体因此绝不会被完整缓冲。
 */
async function readBody(request: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    const buffer = chunk as Buffer
    size += buffer.length
    if (size > MAX_BODY_BYTES) throw new TooLargeError()
    chunks.push(buffer)
  }
  return Buffer.concat(chunks).toString('utf8')
}

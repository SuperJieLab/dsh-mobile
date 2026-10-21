/**
 * 面向手机的 HTTP 传输：路由一条请求、执行传输层守卫、把守身份 ——
 * socket 层调用方欠协议的一切，只要不是协议本身。
 *
 * 状态码不是协议 —— 结果由信封携带，协议层拒绝也是 HTTP 200。`/rpc`
 * 承载协议消息；其余只帮人区分「监听器活着」与「什么都没在听」。
 */
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { createServer } from 'node:http'
import { DEFAULT_LIMITS, failure, handle, success, type Limits } from '../protocol/rpc.ts'
import { PROTOCOL_VERSION } from '../wire/rpc.ts'
import type { SessionPort } from '../ports/session.ts'
import type { CommandPort } from '../ports/command.ts'
import type { WritePort } from '../ports/write.ts'
import type { ModelPort } from '../ports/model.ts'
import { CredentialVault } from './credentials.ts'
import type {
  PairRequest, PairResponse, RefreshRequest, RefreshResponse,
} from '../wire/auth.ts'
import { createLogger, LogModule } from '../log.ts'

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

/** 监听器应答一条请求所需的依赖。 */
export interface RpcListenerDeps {
  sessionPort: SessionPort
  limits: Limits
  vault: CredentialVault
  writePort: WritePort
  modelPort: ModelPort | undefined
  commandPort: CommandPort | undefined
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

  if (path !== '/rpc') {
    // 存活探测，以及任何未知路径的回答。纯传输层：不涉协议消息，
    // 也不涉信封。版本号取常量而非硬编码 —— 它能升，这句话不能跟着说谎。
    response.writeHead(path === '/' ? 200 : 404, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(path === '/'
      ? `mac-gateway alive — protocol v${PROTOCOL_VERSION}, POST /rpc for the protocol\n`
      : 'not found\n')
    return
  }

  if (request.method !== 'POST') {
    response.writeHead(405, { 'content-type': 'text/plain; charset=utf-8', allow: 'POST' })
    response.end('use POST /rpc\n')
    return
  }

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
    const answer = await handleAuthOp(op, message, deps.vault)
    response.writeHead(answer.status, { 'content-type': 'application/json; charset=utf-8' })
    response.end(`${JSON.stringify(answer.body)}\n`)
    return
  }

  if (!deps.vault.authenticate(request.headers.authorization)) {
    // info 而非 warn：票过期后的这次 401 是续期编排的正常一环，客户端拿到 401 会
    // 静默换票重试；warn 留给 refresh 本身被拒（关系被掐）。
    log.info(`op "${String(op)}" refused: no live access token`)
    response.writeHead(401, { 'content-type': 'application/json; charset=utf-8' })
    response.end(`${JSON.stringify(failure('unauthenticated', 'missing or expired access token — pair first, then refresh'))}\n`)
    return
  }

  const answer = await handle(message, deps.sessionPort, Date.now, deps.limits, deps.writePort, deps.modelPort, deps.commandPort)
  // 拒绝在服务端留证据：手机对一次失败的写 op 只显示一行状态，对一次失败的读 op
  // 只在它自己那一屏留个提示 —— 归因要回到网关日志。静默的例外见 {@link SILENT_REFUSALS}。
  if (!answer.ok && typeof op === 'string' && !SILENT_REFUSALS.has(op)) {
    log.error(`op "${op}" refused: ${JSON.stringify(answer.error)}`)
  }
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
  response.end(`${JSON.stringify(answer)}\n`)
}

/**
 * 应答 `pair` / `refresh`。放在闸门旁而非 `handle` 内：凭据来自体内而非头部的
 * 消息只有这两条，而其余 op 都要先过头部那道闸。
 *
 * 形状在 `wire/auth.ts`（两端共守）；**校验不在这里，它在 `protocol/auth.ts`
 * 的配对规则里** —— 那四种失败原因必须原样传到手机上，所以这一层不判对错，
 * 只选 HTTP 状态码。
 */
async function handleAuthOp(
  op: 'pair' | 'refresh',
  message: unknown,
  vault: CredentialVault,
): Promise<{ status: number; body: PairResponse | RefreshResponse }> {
  // 字段名从请求形状里取：改名会在这里编译失败，而不是让客户端与服务端各读
  // 一个名字、每次配对都落到 `bad-code-shape`。两者都可能缺 —— 缺了交给规则层
  // 拒绝，所以读取处按 `unknown` 收窄。
  //
  // 不写成 `Partial<PairRequest & RefreshRequest>`：两条 op 的 `op` 是互斥
  // 字面量，交叉之后整个类型塌成 `never`。
  const payload = message as {
    code?: PairRequest['code']
    deviceToken?: RefreshRequest['deviceToken']
  }

  if (op === 'pair') {
    const outcome = vault.pair(payload.code)
    if (!outcome.ok) {
      // 配对失败值得留痕：试错配对码与码过期在这里同形，日志能区分开。
      log.warn(`pair refused: ${outcome.reason}`)
      return { status: 401, body: failure('invalid-pairing-code', outcome.reason) }
    }
    // 关系建立是身份链路的状态迁移，必须留痕（配对成功但列表 401 时先看这里）。
    log.info('pair accepted — device relationship established')
    return { status: 200, body: success({ deviceToken: outcome.deviceToken }) }
  }

  const outcome = vault.refresh(payload.deviceToken)
  if (!outcome.ok) {
    // 服务端掐断关系的唯一时刻 —— 客户端会静默回未配对态，这里不说就没人知道为什么。
    log.warn('refresh refused: unknown device token — relationship severed')
    return {
      status: 401,
      body: failure('unauthenticated', 'unknown device token — pair again'),
    }
  }
  return {
    status: 200,
    body: success({ accessToken: outcome.accessToken, expiresAt: outcome.expiresAt }),
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

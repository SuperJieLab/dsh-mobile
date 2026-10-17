/**
 * 面向手机的 HTTP 传输：路由一条请求、执行传输层守卫、把守身份 ——
 * socket 层调用方欠协议的一切，只要不是协议本身。
 *
 * 状态码不是协议 —— 结果由信封携带，协议层拒绝也是 HTTP 200。`/rpc`
 * 承载协议消息；其余只帮人区分「监听器活着」与「什么都没在听」。
 */
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { createServer } from 'node:http'
import { DEFAULT_LIMITS, handle, type Limits } from '../protocol/rpc.ts'
import { PROTOCOL_VERSION } from '../wire/rpc.ts'
import type { SessionPort } from '../ports/session.ts'
import type { WritePort } from '../ports/write.ts'
import type { ModelPort } from '../ports/model.ts'
import { CredentialVault } from './credentials.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.http)

/** 请求体上限 —— 传输层守卫，不是协议规则：端口 LAN 可达，无界读是内存
 * 耗尽的把手。1 MiB 远高于任何 v2 请求。 */
const MAX_BODY_BYTES = 1_048_576

/** 监听器应答一条请求所需的依赖。 */
export interface RpcListenerDeps {
  sessionPort: SessionPort
  limits: Limits
  vault: CredentialVault
  writePort: WritePort
  modelPort: ModelPort | undefined
}

/**
 * 构建插件自己的 HTTP 监听器：一个 server，`POST /rpc` 走单向调用，
 * 流升级共享端口（与其他请求同一闸门 —— 无有效 access token，就没有 101；
 * 见 remote/ws.ts）。
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
    // 也不涉信封。
    response.writeHead(path === '/' ? 200 : 404, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(path === '/' ? 'mac-gateway alive — protocol v2, POST /rpc for the protocol\n' : 'not found\n')
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
    response.end(`${JSON.stringify(refusal('unauthenticated', 'missing or expired access token — pair first, then refresh'))}\n`)
    return
  }

  const answer = await handle(message, deps.sessionPort, Date.now, deps.limits, deps.writePort, deps.modelPort)
  // 拒绝在服务端留证据：写 op 因为手机只显示一行状态；模型 op 因为 T8
  // 真机跑出过一次静默为空的目录 —— 死掉的读 op 不得比失败的写 op 更安静。
  if (!answer.ok && (op === 'session-prompt' || op === 'approval-answer' || op === 'model-select' || op === 'model-catalog')) {
    log.error(`op "${op}" refused: ${JSON.stringify(answer.error)}`)
  }
  response.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
  response.end(`${JSON.stringify(answer)}\n`)
}

/** auth 路径共用的拒绝信封（读路径在 `handle` 内自建）。 */
function refusal(code: string, message: string): { v: number; ok: false; error: { code: string; message: string } } {
  return { v: PROTOCOL_VERSION, ok: false, error: { code, message } }
}

/**
 * 应答 `pair` / `refresh`。放在闸门旁而非 `handle` 内，让协议契约保持为
 * 纯读协议：凭据来自体内而非头部的消息只有这两条。
 */
async function handleAuthOp(
  op: 'pair' | 'refresh',
  message: unknown,
  vault: CredentialVault,
): Promise<{ status: number; body: unknown }> {
  const payload = message as { code?: unknown; deviceToken?: unknown }

  if (op === 'pair') {
    const outcome = vault.pair(payload.code)
    if (!outcome.ok) {
      // 配对失败值得留痕：试错配对码与码过期在这里同形，日志能区分开。
      log.warn(`pair refused: ${outcome.reason}`)
      return { status: 401, body: refusal('invalid-pairing-code', outcome.reason) }
    }
    // 关系建立是身份链路的状态迁移，必须留痕（配对成功但列表 401 时先看这里）。
    log.info('pair accepted — device relationship established')
    return {
      status: 200,
      body: { v: PROTOCOL_VERSION, ok: true, deviceToken: outcome.deviceToken },
    }
  }

  const outcome = vault.refresh(payload.deviceToken)
  if (!outcome.ok) {
    // 服务端掐断关系的唯一时刻 —— 客户端会静默回未配对态，这里不说就没人知道为什么。
    log.warn('refresh refused: unknown device token — relationship severed')
    return {
      status: 401,
      body: refusal('unauthenticated', 'unknown device token — pair again'),
    }
  }
  return {
    status: 200,
    body: { v: PROTOCOL_VERSION, ok: true, accessToken: outcome.accessToken, expiresAt: outcome.expiresAt },
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

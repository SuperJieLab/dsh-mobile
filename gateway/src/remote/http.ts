/**
 * 面向手机的 HTTP 传输：路由一条请求、执行传输层守卫、把守身份 ——
 * socket 层调用方欠协议的一切，只要不是协议本身。
 *
 * 状态码不是协议 —— 结果由信封携带。两条例外都是**身份**而不是业务：没票打要票的端点
 * 是 401，免票端点（`pair` / `refresh`）的失败也是 401 —— 客户端正是靠它判「这条关系
 * 不成立了」。其余一切，连业务拒绝，都是 200。`/api/<命名空间>/<方法>` 承载一元调用；
 * 其余路径只帮人区分「监听器活着」与「什么都没在听」。
 */
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { createServer } from 'node:http'
import type { Limits } from '../protocol/rpc.ts'
import { invokeEndpoint, unaryEndpointOf } from '../protocol/unary-endpoints.ts'
import type { SessionPort } from '../ports/session.ts'
import type { CommandPort } from '../ports/command.ts'
import type { PermissionPort } from '../ports/permission.ts'
import type { WritePort } from '../ports/write.ts'
import type { ModelPort } from '../ports/model.ts'
import type { WorkspacePort } from '../ports/workspace.ts'
import { auditEntryOf, type AuditLog } from '../audit.ts'
import type { Metrics } from '../metrics.ts'
import { CredentialVault } from './credentials.ts'
import { encodeServerResponse, parseClientRequest, type ClientRequest, type RemoteResult } from '../wire/unary.ts'
import { createLogger, LogModule, currentRequestId, mintRequestId, runWithRequestId } from '../log.ts'

const log = createLogger(LogModule.http)

/** 请求体上限 —— 传输层守卫，不是协议规则：端口 LAN 可达，无界读是内存
 * 耗尽的把手。1 MiB 远高于任何 v2 请求。 */
const MAX_BODY_BYTES = 1_048_576

/**
 * 拒绝时**不**留痕的三条读端点 —— 判定方向取「默认留痕」，这张表只装例外。
 *
 * 它们都是纯读：失败在手机上有明确落点（列表的失败横幅、详情的失败态），服务端再记
 * 一条只是把噪声翻倍。方向不能反过来列一张「要留痕的端点」名单 —— 白名单漏掉一个新
 * 端点之后**静默**（它失败时无处归因），而黑名单漏掉只是多一条日志。
 *
 * 表里的名字必须是端点表真登记了的名字：改名或删端点之后留下的死条目意味着这一条
 * 既没有日志、也没人知道它本该静默（`tests/structure.test.ts` 守这一条）。
 */
export const SILENT_REFUSALS: ReadonlySet<string> = new Set([
  'mobile/listSessions',
  'mobile/snapshot',
  'mobile/page',
])

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
 * 构建插件自己的 HTTP 监听器：一个 server，`POST /api/<命名空间>/<方法>` 走一元调用，
 * 流升级共享端口（与其他请求同一闸门 —— 无有效 access token，就没有 101；
 * 见 remote/connection.ts）。
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

  if (path.startsWith('/api/')) {
    // 一元调用：`/api/<命名空间>/<方法>`。端点名进路径是照上游的形状，
    // 判它算不算一条端点、由谁处理，见 {@link respondToEndpoint}。
    if (request.method !== 'POST') {
      response.writeHead(405, { 'content-type': 'text/plain; charset=utf-8', allow: 'POST' })
      response.end('use POST\n')
      return
    }
    await runWithRequestId(requestIdOf(request.headers), () => respondToEndpoint(request, response, path, deps))
    return
  }

  // 存活探测，以及任何未知路径的回答。纯传输层：不涉协议消息，也不涉信封。
  // 那句话要指向真正承载协议的地方 —— 指向一个已删掉的路径会让排障的人找错地方。
  response.writeHead(path === '/' ? 200 : 404, { 'content-type': 'text/plain; charset=utf-8' })
  response.end(path === '/'
    ? 'dsh-mobile-gateway alive — POST /api/<namespace>/<method> for the protocol\n'
    : 'not found\n')
}

/**
 * 从路径取出端点名。**只认恰好两段** —— 一段、三段、空段都不算。
 *
 * 不算的与「算但表里没有」处理相同（404 纯文本），但理由不同：前者还不是一条消息
 * （连 `rpcId` 都没有，包不出信封），后者是一条合格的请求打到了不存在的端点。
 * 两者都不该回信封，否则客户端会得到一条它无法归属的拒绝。
 */
function endpointOfPath(path: string): string | undefined {
  const segments = path.slice('/api/'.length).split('/')
  if (segments.length !== 2) return undefined
  const [namespace, method] = segments
  if (namespace === '' || method === '') return undefined
  return `${namespace}/${method}`
}

/** `/api/<ns>/<method>` 的 POST 分支。已带请求标记。 */
async function respondToEndpoint(
  request: IncomingMessage,
  response: ServerResponse,
  path: string,
  deps: RpcListenerDeps,
): Promise<void> {
  const endpointName = endpointOfPath(path)
  const endpoint = endpointName === undefined ? undefined : unaryEndpointOf(endpointName)
  if (endpointName === undefined || endpoint === undefined) {
    response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' })
    response.end('not found\n')
    return
  }

  let body: string
  try {
    body = await readBody(request)
  } catch (error) {
    response.writeHead(error instanceof TooLargeError ? 413 : 400, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`malformed request: ${String(error)}\n`)
    return
  }

  const parsed = parseClientRequest(body)
  if (parsed === undefined) {
    // 外壳不合格时连 `rpcId` 都不可信，包不出可归属的信封 —— 与「解析不了的东西不是消息」同一条分界。
    response.writeHead(400, { 'content-type': 'text/plain; charset=utf-8' })
    response.end('malformed request: not a client-request\n')
    return
  }

  const reply = await answerEndpoint(parsed, endpointName, endpoint, deps, request.headers.authorization)
  response.writeHead(reply.status, { 'content-type': 'application/json; charset=utf-8' })
  response.end(`${encodeServerResponse(parsed.rpcId, reply.result)}\n`)
}

/** 一条已归到端点的请求：判身份、判名字一致、交给处理器。 */
/** 一条端点的应答：状态码只表达「身份成不成立」，业务成败全在 `result` 里。 */
interface EndpointReply {
  readonly status: number
  readonly result: RemoteResult
}

async function answerEndpoint(
  parsed: ClientRequest,
  endpointName: string,
  endpoint: NonNullable<ReturnType<typeof unaryEndpointOf>>,
  deps: RpcListenerDeps,
  authorization: string | undefined,
): Promise<EndpointReply> {
  // 身份先于一切：除免票的两条，没有票的请求不该得到任何业务答复 —— 连「你名字拼错了」
  // 都不该说。顺序反了的话，一条无票的畸形请求会拿到 200，而契约说这种请求是 401。
  //
  // 免票的那两条是「拿票」的端点 —— 要求它们先有票是死锁。
  if (endpoint.unauthenticated !== true && !deps.vault.authenticate(authorization)) {
    // info 而非 warn：票过期后的这次 401 是续期编排的正常一环，客户端会静默换票重试。
    log.info('endpoint refused: no live access token', { endpoint: endpointName })
    return {
      status: 401,
      result: {
        ok: false,
        error: { code: 'unauthenticated', message: 'missing or expired access token — pair first, then refresh', details: {} },
      },
    }
  }

  if (parsed.method !== endpointName) {
    // 信封里的方法名与路径不一致：这是「客户端把两个名字拼错了」，
    // 属于同一处说错了东西，不该落到处理器。
    return {
      status: 200,
      result: {
        ok: false,
        error: {
          code: 'invalid-request',
          message: 'the method in the envelope does not match the endpoint in the path',
          details: { method: parsed.method, endpoint: endpointName },
        },
      },
    }
  }

  const result = await invokeEndpoint(endpointName, parsed.payload.args, {
    ports: {
      session: deps.sessionPort,
      write: deps.writePort,
      model: deps.modelPort,
      command: deps.commandPort,
      workspace: deps.workspacePort,
      permission: deps.permissionPort,
    },
    now: Date.now,
    limits: deps.limits,
    auth: deps.vault,
  })

  if (endpoint.write) {
    deps.auditLog?.append(
      auditEntryOf(endpoint.legacyOp, parsed.payload.args, result, currentRequestId()),
    )
  }
  // 每个端点一次计数，成败各一 —— 审计只记写端点，而「哪个读端点在失败」同样要能回答。
  // 标签沿用旧 op 名：`/metrics` 的历史曲线按它累积，换名字会让曲线断掉。
  deps.metrics?.count('dsh_rpc_requests_total', {
    op: endpoint.legacyOp,
    result: result.ok ? 'ok' : 'refused',
  })
  if (endpoint.unauthenticated === true) {
    // 免票的两条各有自己的说法（配对成功是「关系建立了」的锚点，续期被拒是关系被掐断
    // 的唯一时刻），所以它们由 `logAuthEndpoint` 记，不再叠一条通用的拒绝行。
    logAuthEndpoint(endpointName, result)
  } else if (!result.ok && !SILENT_REFUSALS.has(endpointName)) {
    // 拒绝在服务端留证据：手机对一次失败只显示一行状态，归因要回到网关日志。
    // 静默的例外见 {@link SILENT_REFUSALS}。
    log.error('endpoint refused', { endpoint: endpointName, error: JSON.stringify(result.error) })
  }

  // 免票端点的两种失败（配对码不对 / 关系被撤销）是**身份断言**，不是业务结果：
  // 契约 §4.5 说它们回 401，客户端也据 401 判「这条关系不成立了」——回 200 会让
  // 那条分支走不到，撤销之后只会无限重试。其余端点一律 200，连拒绝也是。
  const status = endpoint.unauthenticated === true && !result.ok ? 401 : 200
  return { status, result }
}

/**
 * 身份链路上的两条留痕 —— 判定在 `protocol/auth-ops.ts`，这里只负责说给人听。
 *
 * 三条各有各的读者：配对成功是「关系建立了」的锚点（之后列表还 401 就先看它）；
 * 配对失败要能区分「码错了」与「码过期了」；续期被拒是服务端**掐断关系**的唯一时刻。
 *
 * 它挂在**端点名**上：网关这一侧只认端点名，旧 op 名只留给审计与指标的历史词汇。
 */
function logAuthEndpoint(endpoint: string, result: RemoteResult): void {
  if (endpoint === 'mobile/pair') {
    if (result.ok) {
      log.info('pair accepted — device relationship established')
    } else {
      log.warn('pair refused', { error: result.error.message })
    }
    return
  }
  if (!result.ok) {
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

/**
 * 一元端点的表：名字 → 写标记 + 处理器。**这是「哪个名字由谁处理」的唯一判定处。**
 *
 * 名字的类型在 `wire/unary.ts`（两端共守的形状），处理器在这里（协议判定）——
 * 分开放的理由：`wire/` 不许认识处理器（`structure.test.ts` 的「wire/ does not reach
 * outside itself」会拦住）。
 *
 * 表里除了「谁处理」还记着两件事：这条是不是写操作（审计据此决定记不记），以及
 * 它的**旧 op 名**（审计与 `/metrics` 的历史词汇 —— 换名字会让已写下的文件与累积的
 * 曲线对不上）。名字与旧 op 不是一一对应（`session/list` ↔ `list-sessions`），
 * 所以映射写在表里，不另建一张。
 */
import { readErrorOf } from './error-codes.ts'
import { describeError, isNotFound } from '../ports/errors.ts'
import { isPlainObject } from '../wire/fields.ts'
import { refused, type Ports, type StreamOwners } from './rpc.ts'
import { pairOf, refreshOf } from './auth-ops.ts'
import { sessionCreateTargetOf } from '../wire/write.ts'
import type { AuthPort } from './auth-ops.ts'
import type { Identity } from './auth.ts'
import {
  commandCatalogOf,
  commandExecuteOf,
  modelCatalogOf,
  modelSelectOf,
  permissionCatalogOf,
  remoteEventResultValue,
  sessionCreateOf,
  sessionPromptValue,
  workspaceCreateOf,
  workspaceDeleteOf,
} from './rpc.ts'
import { directoryListArgumentsOf } from '../wire/directory.ts'
import type { RemoteResult, UnaryEndpointName } from '../wire/unary.ts'

/**
 * 转发用的取消信号：**永不中止**。
 *
 * HTTP 的断开目前不接到这里（方案「明确不做」）：宿主侧那次读会跑完，代价只是一次
 * 白读。接上去需要给 `remote/http.ts` 加一条 `aborted` → `AbortController` 的线，
 * 而那条线没有任何判据在等它。
 */
const UNCANCELLED = new AbortController().signal

/** 处理器需要的全部外部输入。`now` 注入是为了判据能钉住时间。 */
export interface UnaryContext {
  readonly ports: Ports
  readonly now: () => number
  /** 两条免票端点要它；其余端点用不到，但它们共用同一个上下文。 */
  readonly auth: AuthPort
  /**
   * 这次调用是谁发的。免票端点（`pair` / `refresh`）上**没有** —— 它们的作用就是拿票。
   * 其余端点走到这里时它一定在（401 闸门在 `remote/http.ts`），类型上仍留 `undefined`
   * 是因为两条免票端点共用同一个上下文。
   */
  readonly caller: Identity | undefined
  /** 流归属的查询口 —— 只有 `$events/result` 读它。 */
  readonly owners: StreamOwners
}

/** 一条端点：是不是写操作、要不要票、以及收到 `args` 之后做什么。 */
export interface UnaryEndpoint {
  /** 写操作 —— 审计按它决定记不记。读操作不记：审计回答「谁改了什么」。 */
  readonly write: boolean
  /**
   * 免票端点。只有 `pair` / `refresh`：它们的作用就是**拿票**，
   * 要求票才能拿票是死锁。其余端点一律要票。
   */
  readonly unauthenticated?: boolean
  /**
   * 审计与指标沿用的旧 op 名。
   *
   * 它们不是「过渡期的残留」而是**历史词汇**：审计文件按 `op=` 写、`/metrics` 按
   * `op=` 累积，换一个名字等于让同一件事在历史里有两个写法。端点名是给线上协议用的，
   * 这一格是给运维用的。
   */
  readonly legacyOp: string
  invoke(args: Readonly<Record<string, unknown>>, ctx: UnaryContext): Promise<RemoteResult>
}

/**
 * 已接上的端点。**没登记的名字在路由层就是 404** —— 与「登记了但参数不对」是两种
 * 故障，前者说明两端说不到一处，后者说明同一处说错了东西。
 */
const ENDPOINTS: Partial<Record<UnaryEndpointName, UnaryEndpoint>> = {
  'session/list': {
    legacyOp: 'list-sessions',
    write: false,
    async invoke(args, ctx) {
      // `_request` 是**宿主的参数名**（`SessionListRequest`），不是我们起的容器名 ——
      // 照抄它。缺了或形状不对就拒：静默当空对象收下，会让「客户端少发一层容器」
      // 这件事看起来生效了，而两种补救（改客户端 / 改网关）完全不同。
      const request = args._request
      if (!isPlainObject(request)) {
        return refused('invalid-request', 'session/list takes its arguments under "_request"')
      }
      return { ok: true, value: await ctx.ports.session.list(request, UNCANCELLED) }
    },
  },
  'session/page': {
    legacyOp: 'page',
    write: false,
    async invoke(args, ctx) {
      // 容器名是**宿主形参名**：`controller.page(request, signal)`。少一层就拒 ——
      // 静默当空对象收下会让「客户端少发一层容器」看起来生效了，而宿主的四个水位键
      // 一个都没收到。
      const request = args.request
      if (!isPlainObject(request)) {
        return refused('invalid-request', 'session/page takes its arguments under "request"')
      }
      try {
        return { ok: true, value: await ctx.ports.session.page(request, UNCANCELLED) }
      } catch (error) {
        // 只折一种：宿主说「没有这个会话」。折在这里而不是让 `readErrorOf` 兜底，
        // 是因为它是**正常的答案**（客户端该换一个 id），不是故障。
        if (isNotFound(error)) return refused('unknown-session', describeError(error))
        throw error
      }
    },
  },
  'session/modelCatalog': {
    legacyOp: 'model-catalog',
    write: false,
    invoke(_args, ctx) {
      return modelCatalogOf(ctx.ports.model)
    },
  },
  'commands/list': {
    legacyOp: 'command-catalog',
    write: false,
    invoke(args, ctx) {
      return commandCatalogOf(args, ctx.ports.command)
    },
  },
  'permissionPresets/catalog': {
    legacyOp: 'permission-catalog',
    write: false,
    invoke(args, ctx) {
      return permissionCatalogOf(args, ctx.ports.permission)
    },
  },
  'session/selectModel': {
    legacyOp: 'model-select',
    write: true,
    invoke(args, ctx) {
      return modelSelectOf(args, ctx.ports.model)
    },
  },
  'commands/execute': {
    legacyOp: 'command-execute',
    write: true,
    invoke(args, ctx) {
      return commandExecuteOf(args, ctx.ports.command)
    },
  },
  'session/create': {
    legacyOp: 'session-create',
    write: true,
    async invoke(args, ctx) {
      // 载荷的形状由 `wire/` 的 codec 判（`sessionCreateTargetOf` 的三态）—— 这里不另写
      // 一份「什么算合法」，否则两处会在某个边界上分家。
      const target = sessionCreateTargetOf(args)
      if (target.kind === 'invalid') {
        return refused('invalid-request', 'session-create accepts a non-empty workspaceId or none')
      }
      return sessionCreateOf(
        ctx.ports.write,
        target.kind === 'workspace' ? target.workspaceId : undefined,
      )
    },
  },
  'directoryPicker/list': {
    legacyOp: 'directory-list',
    write: false,
    async invoke(args, ctx) {
      const directory = ctx.ports.directory
      if (directory === undefined) {
        return refused('internal-error', 'directory channel not wired for "directoryPicker/list"')
      }
      const request = directoryListArgumentsOf(args)
      if (request === undefined) {
        return refused('invalid-request', '"path" must be a non-empty string when present')
      }
      return { ok: true, value: await directory.list(request.path, UNCANCELLED) }
    },
  },
  'workspace/create': {
    legacyOp: 'workspace-create',
    write: true,
    invoke(args, ctx) {
      return workspaceCreateOf(args, ctx.ports.workspace)
    },
  },
  'workspace/delete': {
    legacyOp: 'workspace-delete',
    write: true,
    invoke(args, ctx) {
      return workspaceDeleteOf(args, ctx.ports.workspace)
    },
  },
  '$events/result': {
    legacyOp: 'events-result',
    write: true,
    invoke(args, ctx) {
      return remoteEventResultValue(args, ctx.ports.write, ctx.caller, ctx.owners)
    },
  },
  'session/prompt': {
    legacyOp: 'session-prompt',
    write: true,
    invoke(args, ctx) {
      return sessionPromptValue(args, ctx.ports.write)
    },
  },
  'mobile/pair': {
    legacyOp: 'pair',
    write: false,
    unauthenticated: true,
    invoke(args, ctx) {
      return Promise.resolve(pairOf(args.code, ctx.auth))
    },
  },
  'mobile/refresh': {
    legacyOp: 'refresh',
    write: false,
    unauthenticated: true,
    invoke(args, ctx) {
      return Promise.resolve(refreshOf(args.deviceToken, ctx.auth))
    },
  },
}

/** 查表。名字不合法或还没接上都返回 `undefined`。 */
export function unaryEndpointOf(name: string): UnaryEndpoint | undefined {
  return ENDPOINTS[name as UnaryEndpointName]
}

/**
 * 调一条端点，**并把处理器抛出的异常折成拒绝**。
 *
 * 折叠只在这一处：传输层（`remote/http.ts`）与测试辅助都调它，谁都不自己 catch。
 * 分成两处时，一处折了、一处没折，症状是「同一个故障在两条入口下一条回信封、一条
 * 断成未处理的 rejection」—— 而后者在 HTTP 上表现为连接被掐，客户端看到的是传输失败。
 *
 * 折法沿用 `readErrorOf` 的两档：不可解读的日志是 `unreadable-session`，其余
 * `internal-error` —— 换的是信封，不是故障词汇。
 */
export async function invokeEndpoint(
  name: string,
  args: Readonly<Record<string, unknown>>,
  ctx: UnaryContext,
): Promise<RemoteResult> {
  const endpoint = unaryEndpointOf(name)
  if (endpoint === undefined) {
    return { ok: false, error: { code: 'unknown-endpoint', message: `no endpoint "${name}"`, details: {} } }
  }
  try {
    return await endpoint.invoke(args, ctx)
  } catch (error) {
    const refusal = readErrorOf(error)
    return { ok: false, error: { code: refusal.code, message: refusal.message, details: {} } }
  }
}

/** 已登记的名字 —— 判据与将来的「端点清单」共用一份，不另抄。 */
export function registeredEndpointNames(): readonly string[] {
  return Object.keys(ENDPOINTS)
}

/** 这条端点是不是写操作。判据与将来的「端点清单」按它算 —— 表是唯一的判定处。 */
export function isWriteEndpoint(name: string): boolean {
  return ENDPOINTS[name as UnaryEndpointName]?.write === true
}

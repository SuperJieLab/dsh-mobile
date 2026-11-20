/**
 * 一元端点的表：名字 → 写标记 + 处理器。**这是「哪个名字由谁处理」的唯一判定处。**
 *
 * 名字的类型在 `wire/unary.ts`（两端共守的形状），处理器在这里（协议判定）——
 * 分开放的理由：`wire/` 不许认识处理器（`structure.test.ts` 的「wire/ does not reach
 * outside itself」会拦住）。
 *
 * 过渡期：旧的一元路径（`POST /rpc` + `{v, op}`）还在，两边共用同一个取值函数
 * （例如 `listSessionsOf`），所以同一个功能不会有两份装配。旧路径在最后一轮删除。
 */
import { readErrorOf } from './error-codes.ts'
import type { Limits, Ports } from './rpc.ts'
import { pairOf, refreshOf } from './auth-ops.ts'
import type { AuthPort } from './auth-ops.ts'
import {
  approvalAnswerValue,
  commandCatalogOf,
  commandExecuteOf,
  listSessionsOf,
  modelCatalogOf,
  modelSelectOf,
  pageOf,
  permissionCatalogOf,
  permissionSelectOf,
  sessionCreateOf,
  sessionPromptValue,
  snapshotOf,
  workspaceCreateOf,
  workspaceDeleteOf,
} from './rpc.ts'
import type { RemoteResult, UnaryEndpointName } from '../wire/unary.ts'

/** 处理器需要的全部外部输入。`now` 注入是为了判据能钉住时间。 */
export interface UnaryContext {
  readonly ports: Ports
  readonly now: () => number
  readonly limits: Limits
  /** 两条免票端点要它；其余端点用不到，但它们共用同一个上下文。 */
  readonly auth: AuthPort
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
   * 过渡期用的旧 op 名。旧路径（`POST /rpc`）按它记审计与指标；两条路径的名字
   * 不是一一对应（`mobile/listSessions` ↔ `list-sessions`），所以映射写在表里，
   * 不另建一张。旧路径删掉之后这一格随之消失。
   */
  readonly legacyOp: string
  invoke(args: Readonly<Record<string, unknown>>, ctx: UnaryContext): Promise<RemoteResult>
}

/** 鉴权端口与端点表放在一起：两条免票端点是这张表里唯一的例外。 */
export type UnaryAuthPort = AuthPort

/**
 * 已接上的端点。**没登记的名字在路由层就是 404** —— 与「登记了但参数不对」是两种
 * 故障，前者说明两端说不到一处，后者说明同一处说错了东西。
 */
const ENDPOINTS: Partial<Record<UnaryEndpointName, UnaryEndpoint>> = {
  'mobile/listSessions': {
    legacyOp: 'list-sessions',
    write: false,
    async invoke(_args, ctx) {
      return { ok: true, value: await listSessionsOf(ctx.ports.session, ctx.ports.workspace, ctx.now) }
    },
  },
  'mobile/snapshot': {
    legacyOp: 'snapshot',
    write: false,
    invoke(args, ctx) {
      return snapshotOf(args, ctx.ports.session, ctx.limits)
    },
  },
  'mobile/page': {
    legacyOp: 'page',
    write: false,
    invoke(args, ctx) {
      return pageOf(args, ctx.ports.session)
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
  'mobile/permissionCatalog': {
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
  'mobile/permissionSelect': {
    legacyOp: 'permission-select',
    write: true,
    invoke(args, ctx) {
      return permissionSelectOf(args, ctx.ports.permission)
    },
  },
  'session/create': {
    legacyOp: 'session-create',
    write: true,
    async invoke(args, ctx) {
      // 载荷形状先判：它是「这条请求的语义」，与「端口有没有接」是两件事。
      const workspaceId = args.workspaceId
      if (workspaceId !== undefined && (typeof workspaceId !== 'string' || workspaceId === '')) {
        return {
          ok: false,
          error: {
            code: 'invalid-request',
            message: 'session-create accepts a non-empty workspaceId or none',
            details: {},
          },
        }
      }
      return sessionCreateOf(ctx.ports.write, workspaceId as string | undefined)
    },
  },
  'mobile/workspaceCreate': {
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
  'mobile/approvalAnswer': {
    legacyOp: 'approval-answer',
    write: true,
    invoke(args, ctx) {
      return approvalAnswerValue(args, ctx.ports.write)
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
 * `internal-error`。与旧路径逐字相同 —— 迁移换的是信封，不是故障词汇。
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

/** 这条端点是不是写操作。新路径的审计按它判，不再读请求体里的旧 `op`。 */
export function isWriteEndpoint(name: string): boolean {
  return ENDPOINTS[name as UnaryEndpointName]?.write === true
}

/**
 * 写端点的旧 op 名 —— 给旧路径的审计对账用。
 *
 * 存在的理由：过渡期两条路径各记各的审计，若两份清单能漂，「同一个写操作在新旧两条
 * 路径上一条被记、一条没记」就没有任何东西看得见。这条函数让漂移可断言。
 */
export function writeEndpointLegacyOps(): readonly string[] {
  return Object.values(ENDPOINTS)
    .filter(endpoint => endpoint.write)
    .map(endpoint => endpoint.legacyOp)
}

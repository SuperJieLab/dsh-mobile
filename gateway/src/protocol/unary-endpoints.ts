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
import type { Limits, Ports } from './rpc.ts'
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
}

/** 一条端点：是不是写操作，以及收到 `args` 之后做什么。 */
export interface UnaryEndpoint {
  readonly write: boolean
  invoke(args: Readonly<Record<string, unknown>>, ctx: UnaryContext): Promise<RemoteResult>
}

/**
 * 已接上的端点。**没登记的名字在路由层就是 404** —— 与「登记了但参数不对」是两种
 * 故障，前者说明两端说不到一处，后者说明同一处说错了东西。
 */
const ENDPOINTS: Partial<Record<UnaryEndpointName, UnaryEndpoint>> = {
  'mobile/listSessions': {
    write: false,
    async invoke(_args, ctx) {
      return { ok: true, value: await listSessionsOf(ctx.ports.session, ctx.ports.workspace, ctx.now) }
    },
  },
  'mobile/snapshot': {
    write: false,
    invoke(args, ctx) {
      return snapshotOf(args, ctx.ports.session, ctx.limits)
    },
  },
  'mobile/page': {
    write: false,
    invoke(args, ctx) {
      return pageOf(args, ctx.ports.session)
    },
  },
  'session/modelCatalog': {
    write: false,
    invoke(_args, ctx) {
      return modelCatalogOf(ctx.ports.model)
    },
  },
  'commands/list': {
    write: false,
    invoke(args, ctx) {
      return commandCatalogOf(args, ctx.ports.command)
    },
  },
  'mobile/permissionCatalog': {
    write: false,
    invoke(args, ctx) {
      return permissionCatalogOf(args, ctx.ports.permission)
    },
  },
  'session/selectModel': {
    write: true,
    invoke(args, ctx) {
      return modelSelectOf(args, ctx.ports.model)
    },
  },
  'commands/execute': {
    write: true,
    invoke(args, ctx) {
      return commandExecuteOf(args, ctx.ports.command)
    },
  },
  'mobile/permissionSelect': {
    write: true,
    invoke(args, ctx) {
      return permissionSelectOf(args, ctx.ports.permission)
    },
  },
  'session/create': {
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
    write: true,
    invoke(args, ctx) {
      return workspaceCreateOf(args, ctx.ports.workspace)
    },
  },
  'workspace/delete': {
    write: true,
    invoke(args, ctx) {
      return workspaceDeleteOf(args, ctx.ports.workspace)
    },
  },
  'mobile/approvalAnswer': {
    write: true,
    invoke(args, ctx) {
      return approvalAnswerValue(args, ctx.ports.write)
    },
  },
  'session/prompt': {
    write: true,
    invoke(args, ctx) {
      return sessionPromptValue(args, ctx.ports.write)
    },
  },
}

/** 查表。名字不合法或还没接上都返回 `undefined`。 */
export function unaryEndpointOf(name: string): UnaryEndpoint | undefined {
  return ENDPOINTS[name as UnaryEndpointName]
}

/** 已登记的名字 —— 判据与将来的「端点清单」共用一份，不另抄。 */
export function registeredEndpointNames(): readonly string[] {
  return Object.keys(ENDPOINTS)
}

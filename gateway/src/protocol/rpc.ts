/**
 * 协议判定：一条端点调用进，一个 `RemoteResult` 出。
 *
 * 注入数据源的普通 async 函数：无 HTTP、无 socket、无 DSH 运行时、无会话存储。
 * 传输层（`remote/http.ts`）与测试辅助都经 `protocol/unary-endpoints.ts` 的表找到
 * 这里 —— **本文件不认识 URL**，也不认识信封，它只回答「这次调用成没成、值是什么」。
 *
 * **两条读端点已不再在这里**：`session/list`、`session/page` 都是转发（各自的
 * 表项在 `./unary-endpoints.ts`），窗口怎么切、水位怎么算都由宿主回答。本文件只剩
 * 写面的判定与两条目录/当前值的读。`snapshot`/`page` 的水位算术随它们一起退场 ——
 * 抄一份宿主的规则，在宿主改规则时不会红。
 */

import type { SessionPort } from '../ports/session.ts'
import type { ModelPort } from '../ports/model.ts'
import type { WritePort } from '../ports/write.ts'
import type { CommandPort } from '../ports/command.ts'
import type { PermissionPort } from '../ports/permission.ts'
import type { WorkspacePort } from '../ports/workspace.ts'
import type { RemoteResult } from '../wire/unary.ts'
import { modelSelectRequestOf } from '../wire/model.ts'
import { commandExecuteRequestOf } from '../wire/command.ts'
import { remoteEventResultOf, sessionPromptOf } from '../wire/write.ts'
import { workspaceIdOf, workspaceNameOf } from '../wire/workspace.ts'
import { isPositiveInteger } from '../wire/fields.ts'
import type { Identity } from './auth.ts'

/**
 * 流归属的查询口 —— 判定侧要看的**唯一一面**。
 *
 * 机制（谁占着 socket、哪条流是谁的）在 `remote/identity-registry.ts`；这里只要
 * 「这条 clientId 的主人是谁」。接口归消费方：`remoteEventResultValue` 是唯一的消费者。
 */
export interface StreamOwners {
  /** 这条流的主人（身份 id）；没有这条流时为 `undefined`。 */
  ownerOf(clientId: string): string | undefined
}

/**
 * 传输层的字节上界。
 *
 * **只剩一格**：两条一元读端点退场之后，「一条应答至多多少事件 / 多少字节」不再
 * 是网关的事 —— 分页的窗口由宿主切（`session/page`），网关能施加的只有 WSS 一帧的
 * 尺寸。`maxDeltaEvents` / `maxDeltaBytes` 随 HTTP 快照端点一起删了：留着就是
 * 两个没有读者的旋钮，而配置文档会继续承诺一个并不存在的截断。
 */
export interface Limits {
  /**
   * follow 打开那一帧的字节上界（R9 期1）。**硬上限** —— 装不下就按轮边界收窄，
   * 连一轮都装不下则拒绝。它约束的是传输，不是会话内容。
   */
  maxOpeningBytes: number
}

/**
 * LAN 演示的上限：宽到很少生效，小到确实有界。`maxOpeningBytes` 取 4 MiB ——
 * 比一个典型会话的整条窗口宽出数倍，于是普通会话根本不进收窄路径。
 */
export const DEFAULT_LIMITS: Limits = { maxOpeningBytes: 4 * 1024 * 1024 }


/**
 * 一次调用要用到的数据源。
 *
 * **具名，不按位置。** 除 `session` 外都可选，而可选参数按位置传时「顺序写错」不会
 * 编译失败 —— 它会让某个 op 拿到另一个端口，在运行时表现为「权限 op 读到了工作空间」
 * 这类静默错位。具名之后，漏传是缺席、传错是类型错。
 */
export interface Ports {
  /** 读路径与列表路径的唯一必需依赖。 */
  session: SessionPort
  write?: WritePort
  model?: ModelPort
  command?: CommandPort
  workspace?: WorkspacePort
  permission?: PermissionPort
}

/**
 * 建一个空会话。`ok` 意为**宿主建出来或复用了**一个空会话，`sessionId` 是它给的那个 ——
 * 网关不造 id、也不缓存：列表是会话的真相，这里只负责把这一次创建的结果答回去。
 *
 * 宿主失败**不在这里折**：`invokeEndpoint` 的 catch 用 `readErrorOf` 统一折成
 * `internal-error` 并把上游的话带进 message。本层不记日志，排障看宿主侧。
 */
export async function sessionCreateOf(
  write: WritePort | undefined,
  workspaceId: string | undefined,
): Promise<RemoteResult> {
  // 仅只读测试装配会缺 `write`；生产必接线，此拒绝在生产不可达。
  if (write === undefined) return refused('internal-error', 'write channel not wired for "session-create"')
  return { ok: true, value: { sessionId: await write.createSession(workspaceId) } }
}

/**
 * 在固定根下造一个工作空间。
 *
 * 名字不合法时在这里就拒，**不碰文件系统** —— 形状与语义合成一次判断，因为对客户端
 * 而言两者的补救动作相同（改字重发）。
 */
export async function workspaceCreateOf(
  args: Record<string, unknown>,
  workspace: WorkspacePort | undefined,
): Promise<RemoteResult> {
  if (workspace === undefined) return refused('internal-error', 'workspace channel not wired for "workspace-create"')
  const name = workspaceNameOf(args)
  if (name === undefined) {
    return refused('invalid-request', 'workspace-create needs a name that is one non-blank path segment')
  }
  const made = await workspace.create(name)
  return {
    ok: true,
    value: { workspaceId: made.workspaceId, title: made.title, created: made.created },
  }
}

/**
 * 解除一个工作空间的注册。
 *
 * `ok` 意为**它已经不在列表里了** —— 是真删掉的、还是本来就没有，客户端不需要知道
 * （两种结局要做的事完全一样：关掉确认框、重拉一次）。所以应答里没有 `deleted`。
 *
 * 宿主失败**不在这里折**：`invokeEndpoint` 的 catch 用 `readErrorOf` 统一折成 `internal-error`。
 * 「删一个已经不在的算成功」那条住在适配层（`deleteWorkspaceIn`），它认得 not-found。
 */
export async function workspaceDeleteOf(
  args: Record<string, unknown>,
  workspace: WorkspacePort | undefined,
): Promise<RemoteResult> {
  if (workspace === undefined) return refused('internal-error', 'workspace channel not wired for "workspace-delete"')
  const workspaceId = workspaceIdOf(args)
  if (workspaceId === undefined) {
    return refused('invalid-request', 'workspace-delete needs a non-blank workspaceId')
  }
  await workspace.delete(workspaceId)
  return { ok: true, value: {} }
}

/**
 * 越权应答的拒绝 —— **把留痕要用的四个事实装进 `details`**。
 *
 * 为什么不在这里记日志：`protocol/` 只许认识 `wire/` 与 `ports/`
 * （`tests/structure.test.ts` 的 V2b），而日志出口在顶层 `log.ts`。所以判定层交出
 * 事实，由传输层（`remote/http.ts`）写成那一条 warn —— 判与记各归各家，事实不在
 * 中途被字符串化成一个只有人读得懂的句子。
 */
function notOwner(
  caller: Identity,
  target: { readonly clientId: string; readonly eventId: string },
  owner: string | undefined,
  message: string,
): RemoteResult {
  return {
    ok: false,
    error: {
      code: 'not-owner',
      message,
      details: {
        caller: caller.id,
        client: target.clientId,
        event: target.eventId,
        ...(owner === undefined ? {} : { owner }),
      },
    },
  }
}

/**
 * 归属的四步判定 —— **与「这是哪一类待答调用」无关，所以两个端点共用这一份**。
 *
 * 复制一份的症状是两处会在 `not-owner` 的 `details` 或文案上分家，而客户端只看码，
 * 分家时没有任何一处会报错。
 *
 * 四步的顺序是契约的一部分：没有身份先说装配错（不是身份失败），能答与不能答先于
 * 「这条流在不在」—— 否则一个不能答的身份拿别人的 `clientId` 会得到 `not-owner`，
 * 而它该得到的是同一个码，只是理由不同（两者码相同，`details` 与文案不同）。
 */
export function ownedAnswerOf(
  target: { readonly clientId: string; readonly eventId: string },
  caller: Identity | undefined,
  owners: StreamOwners,
): { readonly ok: true } | { readonly ok: false; readonly refusal: RemoteResult } {
  // ① 没有身份：生产上到不了这里（401 闸门在 `remote/http.ts`）。所以这是**装配错误**，
  //    不是身份失败 —— 回 `unauthenticated` 会让它变成一条 200 的「没身份」，而契约
  //    说那个码总是 401（那是闸门的形状，不是判定层的）。
  if (caller === undefined) {
    return {
      ok: false,
      refusal: refused('internal-error',
        'an answer reached the judge without an identity — the auth gate is misassembled'),
    }
  }
  // ② 身份在，但它不是「能答挂起项」的那一类。
  if (!caller.canAnswer) {
    return {
      ok: false,
      refusal: notOwner(caller, target, undefined, 'this identity may not answer pending requests'),
    }
  }
  // ③ 这条流不在（从未下发、已换代、或连接已断）。它与「你在答别人的流」结局相同：
  //    客户端要做的事一样（重开流或放弃），所以同一个码。
  const owner = owners.ownerOf(target.clientId)
  if (owner === undefined) {
    return {
      ok: false,
      refusal: notOwner(caller, target, undefined,
        `no open stream called "${target.clientId}" — it was never offered, or it has been replaced`),
    }
  }
  // ④ 流在，但不是你的。
  if (owner !== caller.id) {
    return {
      ok: false,
      refusal: notOwner(caller, target, owner, 'that stream belongs to another identity'),
    }
  }
  return { ok: true }
}

/**
 * 投递一条 `$events/result`。
 *
 * `ok` 意为**上游收下了这次应答**（结算了 waterfall，或对已结算事件做了幂等 no-op）。
 * 网关不判「这条还在不在」—— 上游对不存在的 `eventId` 是 no-op，本地判会把它写成
 * `unknown-approval`，而那与上游的结论相反（F3 第 3 期删掉了那条本地判定）。  // terms-ok: 说明被删的那条判定
 *
 * `outcome` 原样交给端口：网关不解释结局词汇，也不按交互种类分派。
 */
export async function remoteEventResultValue(
  args: Record<string, unknown>,
  write: WritePort | undefined,
  caller: Identity | undefined,
  owners: StreamOwners,
): Promise<RemoteResult> {
  if (write === undefined) return refused('internal-error', 'write channel not wired for "$events/result"')
  const result = remoteEventResultOf(args)
  if (result === undefined) {
    return refused('invalid-request',
      '$events/result needs clientId, eventId, and outcome{kind:"next"|"result"|"rejected"}')
  }
  const ownership = ownedAnswerOf(result, caller, owners)
  if (!ownership.ok) return ownership.refusal

  const outcome = await write.answerEvent(result)
  if (outcome === 'undelivered') {
    return refused('internal-error',
      `the gateway refused the answer for "${result.eventId}" — see the gateway log for its code`)
  }
  return { ok: true, value: { ok: true } }
}

/**
 * 收纳一条 prompt。`ok` 意为*已接受进收件箱* —— 回复本体经流到达。
 *
 * 五个字段原样交给宿主：`mode` 不再固定成 `queue`，`content` 不再由网关拼一段文本。
 */
export async function sessionPromptValue(
  args: Record<string, unknown>,
  write: WritePort | undefined,
): Promise<RemoteResult> {
  if (write === undefined) return refused('internal-error', 'write channel not wired for "session-prompt"')
  const prompt = sessionPromptOf(args)
  if (prompt === undefined) {
    return refused('invalid-request',
      'session-prompt needs request{requestId, sessionId, mode ("queue" | "steer"), content ([{type:"text",text}])}')
  }
  const outcome = await write.promptSession(prompt)
  if (outcome === 'unknown-session') {
    return refused('unknown-session', `no stored session "${prompt.sessionId}"`)
  }
  return { ok: true, value: { accepted: true } }
}

/**
 * 安装一条会话级模型选择。`ok` 意为*已为下一个请求装好* —— 持久的
 * `model/selection` 事件经流到达客户端，展示对账的正是它。
 * 上游的拒绝保留自己的码：`session/model-unavailable` 说模型不可路由，
 * 与畸形请求是不同的补救。
 */
export async function modelSelectOf(
  args: Record<string, unknown>,
  model: ModelPort | undefined,
): Promise<RemoteResult> {
  if (model === undefined) return refused('internal-error', 'model channel not wired for "model-select"')
  const request = modelSelectRequestOf(args)
  if (request === undefined) {
    return refused('invalid-request', 'model-select needs sessionId, provider, and model')
  }
  const outcome = await model.select(request)
  if (!outcome.ok) return refused(outcome.code, outcome.message)
  return { ok: true, value: { selected: { ...outcome.selected } } }
}

/**
 * 模型目录。端口缺席是装配层宣布过的事实（`faces.ts` 在宿主没有模型切面时
 * 返回 `undefined` 并留痕），所以这一支在生产也可达 —— 拒答而不是崩。
 *
 * 值不重建：宿主的目录就是线上形状（四个键，含 `routableProviders`）。逐字段抄一遍
 * （`{default, groups, failures}`）正是上一版剥掉 `routableProviders` 的原因 ——
 * 抄的人只会抄他记得的那几格。
 */
export async function modelCatalogOf(model: ModelPort | undefined): Promise<RemoteResult> {
  if (model === undefined) return refused('internal-error', 'model channel not wired for "model-catalog"')
  const catalog = await model.catalog()
  return { ok: true, value: catalog }
}

/**
 * 命令列表：该 agent 此刻能用的命令，**描述符原样**（裸数组，不套 `{commands}`）。
 *
 * agent 不在 → `unknown-session`（不是空数组）：没有 agent 就没有 per-agent 的命令集，
 * 空数组会让客户端把「这个会话没了」误读成「这个会话没有命令」。
 */
export async function commandCatalogOf(
  args: Record<string, unknown>,
  command: CommandPort | undefined,
): Promise<RemoteResult> {
  // 仅只读测试装配会缺这个端口：生产装配的命令端口总在，服务缺席由那次调用抛出
  // （折成 `internal-error`），不在这里判。
  if (command === undefined) return refused('internal-error', 'command channel not wired for "command-catalog"')
  const agentId = args.agentId
  if (typeof agentId !== 'string' || agentId === '') {
    return refused('unknown-session', 'agentId must be a non-empty string')
  }
  const commands = await command.list(agentId)
  if (commands === undefined) return refused('unknown-session', `no live session "${agentId}"`)
  return { ok: true, value: [...commands] }
}

/**
 * 执行一行命令。`ok` 意为*已受理* —— 结果从流里的 `command/run` / `command/done` 来，
 * 回包里没有、也不该有执行结果。
 *
 * 两类拒绝保留自己的码：`unknown-command` 说那一行解析不出已注册的命令（客户端改字），
 * 与「这条命令执行失败」（流里的那一行）是不同的补救。
 */
export async function commandExecuteOf(
  args: Record<string, unknown>,
  command: CommandPort | undefined,
): Promise<RemoteResult> {
  if (command === undefined) return refused('internal-error', 'command channel not wired for "command-execute"')
  const request = commandExecuteRequestOf(args)
  if (request === undefined) {
    return refused('invalid-request',
      'command-execute needs agentId, a line starting with "/", and empty submittedAttachments')
  }
  const outcome = await command.execute(request.agentId, request.line)
  if (!outcome.ok) return refused(outcome.code, outcome.message)
  return { ok: true, value: { commandId: outcome.commandId } }
}

/**
 * 权限目录：此刻能选什么、装配的默认档是什么。
 *
 * **一条只读、无参的端点**：目录是进程级的；「这个会话现在是哪一档」在 `permissions`
 * 投影里（`session/control`），不在这条应答里。合成一处会让「目录新、当前值旧」无从分辨。
 *
 * 服务缺席时**三键一起缺席**（`{}`）：客户端据此不画那一格。空数组是另一件事 ——
 * 服务在、一项都没配，界面照画（点开是空的）。
 */
export async function permissionCatalogOf(
  _args: Record<string, unknown>,
  permission: PermissionPort | undefined,
): Promise<RemoteResult> {
  if (permission === undefined) return refused('internal-error', 'permission channel not wired for "permission-catalog"')
  const catalog = await permission.catalog()
  return { ok: true, value: catalog === undefined ? {} : catalog }
}

/**
 * 无意义的上限不得变成卡死：非正或非整数即回退默认值。
 *
 * 唯一读者是打开帧的字节上界（`remote/connection.ts`）—— 一个非正的界会让每一次
 * 打开都被判成「装不下」。
 */
export function positiveOrDefault(value: number | undefined, fallback: number): number {
  return value !== undefined && isPositiveInteger(value) ? value : fallback
}

/**
 * 一次失败的形状（三格，`details` 恒为对象）。
 *
 * 全仓唯一的失败构造点：处理器在判定不下去时用它，`invokeEndpoint` 折异常时也用它 ——
 * 于是「失败恒三键」这件事只有一个出处，而不是每个端点各拼一次。
 */
export function refused(
  code: string,
  message: string,
  details: Record<string, unknown> = {},
): RemoteResult {
  return { ok: false, error: { code, message, details } }
}


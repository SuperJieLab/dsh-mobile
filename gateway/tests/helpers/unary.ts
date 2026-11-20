/**
 * 测试用的一元入口：绕过 HTTP，直接按端点名调处理器。
 *
 * 为什么要有它：`protocol/` 的判据不该为了发一条请求去起监听器 —— 那些判据要控的是
 * 「数据源给什么、处理器怎么答」，网络与鉴权是别人的事。从前这个入口是 `handle({v, op})`，
 * 现在信封换成端点寻址，形状也就换成 `(端点名, args)`。
 *
 * **它只做路由与上下文装配**，不加任何判定：真路径上「这个名字认不认得」「票够不够」
 * 由 `remote/http.ts` 判，那些由 `http-routing` / `http-auth` 两个测试守。
 */
import { DEFAULT_LIMITS, type Limits, type Ports, type StreamOwners } from '../../src/protocol/rpc.ts'
import { invokeEndpoint } from '../../src/protocol/unary-endpoints.ts'
import type { AuthPort } from '../../src/protocol/auth-ops.ts'
import type { Identity } from '../../src/protocol/auth.ts'
import type { RemoteResult } from '../../src/wire/unary.ts'

/** 不碰凭据：需要真的配对/续期的判据直接引 `auth-ops`，不走这里。 */
const unusedAuth: AuthPort = {
  pair: () => ({ ok: false, reason: 'not used by this test' }),
  refresh: () => ({ ok: false }),
}

/**
 * 判据里的「那个客户端」与「它那条流」。
 *
 * 归属判定需要两个东西，判据不该每条都自己造一遍：一个身份，和一条属于它的流。
 * 名字写在这里而不是各测试里，是为了让「谁的流」在断言里读得出来。
 */
export const TEST_CALLER: Identity = { id: 'test-caller', canAnswer: true }
export const TEST_CLIENT_ID = 'c-test'

/** 一条属于 {@link TEST_CALLER} 的流；其余 clientId 都没有主人。 */
const defaultOwners: StreamOwners = {
  ownerOf: (clientId: string) => (clientId === TEST_CLIENT_ID ? TEST_CALLER.id : undefined),
}

/**
 * 发一次一元调用，拿到**新结果形状**（`{ok, value}` / `{ok, error}`）。
 *
 * @param endpoint - 端点名，与 `UNARY_ENDPOINT_NAMES` 同表。
 * @param args - `payload.args` 的内容。
 * @param ports - 数据源；与从前一样由判据自己造。
 * @param now - 注入的时钟：`serverTime` 这类读数要能钉住。
 */
export async function invoke(
  endpoint: string,
  args: Record<string, unknown>,
  ports: Ports,
  now: () => number = Date.now,
  limits: Limits = DEFAULT_LIMITS,
  caller: Identity | undefined = TEST_CALLER,
  owners: StreamOwners = defaultOwners,
): Promise<RemoteResult> {
  // 走 `invokeEndpoint` 而不是查表后直接调：异常折叠也必须在这里生效，
  // 否则「处理器抛错折成 internal-error」那几条判据在绕过 HTTP 时会红在未处理的异常上。
  return invokeEndpoint(endpoint, args, { ports, now, limits, auth: unusedAuth, caller, owners })
}

/**
 * 取一条成功结果的业务字段，**失败时直接抛** —— 判据里 `assert.equal(result.ok, true)`
 * 之后再解包是重复的，而 `value!` 这种非空断言会把一次失败变成 `undefined` 在身上流动，
 * 最后红在一句莫名的 deepEqual 上。
 */
export function valueOf<T = Record<string, unknown>>(result: RemoteResult): T {
  if (!result.ok) {
    throw new Error(`expected a successful result, got ${result.error.code}`)
  }
  return result.value as T
}

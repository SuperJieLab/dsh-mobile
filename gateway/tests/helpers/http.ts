/**
 * 一元调用的测试辅助：把一条请求按信封发出去，再把 `result` 铺平一层。
 *
 * **为什么铺平**：断言关心的是业务字段（`sessions` / `selected` / `error.code`），
 * 而不是信封的层级。信封的形状由 `protocol/unary-shape.test.ts` 与
 * `protocol/contract-shape.test.ts` 单独守；这里每句都写 `body.result.value.sessions`
 * 只会让「信封对不对」与「业务对不对」混在同一行断言里，红的时候看不出是哪一类。
 *
 * 端点名同时进路径与 `method`：`remote/http.ts` 会拒掉两者不一致的请求，
 * 所以这个辅助发的就是一条**良构**请求，除非调用方故意绕开它。
 */
export interface UnaryAnswer {
  readonly status: number
  readonly ok: boolean
  readonly error?: { code: string; message: string; details: Record<string, unknown> }
  readonly [field: string]: unknown
}

/**
 * 一条请求的体。`rpcId` 固定 —— 判据不验它，验它的是 `unary-shape.test.ts`。
 *
 * 不导出：发请求只有 `postEndpoint` / `call` 两条路。放开第三处「自己拼一个体」的口子，
 * 就有第三处可以拼错而没人发现。
 */
function envelopeOf(
  endpoint: string,
  args: Record<string, unknown> = {},
  rpcId = 'test-rpc',
): Record<string, unknown> {
  return { type: 'client-request', rpcId, method: endpoint, payload: { args } }
}

/** 发一条一元调用，原样交出 `Response`（要给「体不是信封」的判据用）。 */
export async function postEndpoint(
  base: string,
  endpoint: string,
  args: Record<string, unknown> = {},
  access?: string,
): Promise<Response> {
  return fetch(`${base}/api/${endpoint}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...access === undefined ? {} : { authorization: `Bearer ${access}` },
    },
    body: JSON.stringify(envelopeOf(endpoint, args)),
  })
}

/**
 * 发一条一元调用，**不铺平**：`value` 原样放在 `value` 那一格。
 *
 * 铺平只对「业务字段是对象」的应答成立。`commands/list` 回的是**裸数组** ——
 * 展开成对象会变成 `{0:…, 1:…}`，读 `row.name` 就成了 undefined。
 */
export async function callRaw(
  base: number | string,
  endpoint: string,
  args: Record<string, unknown> = {},
  access?: string,
): Promise<{ status: number; ok: boolean; value?: unknown; error?: UnaryAnswer['error'] }> {
  const url = typeof base === 'number' ? `http://127.0.0.1:${base}` : base
  const response = await postEndpoint(url, endpoint, args, access)
  const body = await response.json() as {
    result?: { ok?: boolean; value?: unknown; error?: UnaryAnswer['error'] }
  }
  const result = body.result ?? { ok: false }
  return {
    status: response.status,
    ok: result.ok === true,
    ...result.error === undefined ? {} : { error: result.error },
    ...result.ok === true ? { value: result.value } : {},
  }
}

/**
 * 发一条一元调用并按 `result` 铺平。
 *
 * `base` 收端口号或基址两种写法：这个仓库的测试一半从 `install()` 拿到端口、
 * 一半自己起监听器拿到基址，硬统一成一种会让调用点各写一遍模板串。
 */
export async function call(
  base: number | string,
  endpoint: string,
  args: Record<string, unknown> = {},
  access?: string,
): Promise<UnaryAnswer> {
  const url = typeof base === 'number' ? `http://127.0.0.1:${base}` : base
  const response = await postEndpoint(url, endpoint, args, access)
  const body = await response.json() as {
    result?: { ok?: boolean; value?: Record<string, unknown>; error?: UnaryAnswer['error'] }
  }
  const result = body.result ?? { ok: false }
  // 成与败各带一层：成功装 `value`，失败装 `error`。铺平之后调用点只读 `ok` 与业务字段。
  return {
    status: response.status,
    ok: result.ok === true,
    ...result.error === undefined ? {} : { error: result.error },
    ...result.ok === true ? result.value ?? {} : {},
  } as UnaryAnswer
}

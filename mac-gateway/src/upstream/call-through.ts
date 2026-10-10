/**
 * 按形参名调用 DSH 宿主，而不是按位置。位置是内部细节，不是契约：网关的私有
 * 成员可能在我们关心的那个参数之前新增一个参数。名字能挺过这种变化，也能挺过
 * Cordis 对服务成员的多行改写。
 *
 * 形参表读不出（bind、native）时回退到按位置，未知名字取它的位置槽 ——
 * 对该实参是垃圾值，但对 `signal` 永远不是，它是开流唯一不可缺的实参。
 */

/**
 * 上游 opener 的形参表会随运行时版本变长：`uplink` / `peer` 插在 `signal` 前面，按位置传的取消
 * 信号落进 uplink 槽，
 * 真正的 `signal` 成了 `undefined`，网关内部 `AbortSignal.any([undefined, ...])`
 * 当场抛错（真机日志 `signals[0] is not of type AbortSignal.`）—— 中继每一代都死在建流那一步。
 * 形参名是唯一稳的锚点，实参一律按名填（{@link callThrough}）。
 */
export function openStreamThrough(
  opener: (...args: unknown[]) => Promise<AsyncIterable<unknown>>,
  opening: StreamOpening,
): Promise<AsyncIterable<unknown>> {
  return callThrough(opener, {
    endpoint: opening.endpoint,
    payload: opening.payload,
    uplink: emptyUplink(),
    // `undefined` 是操作者自己的进程内载具（types.d.ts:83）。
    peer: undefined,
    signal: opening.signal,
  })
}

/** 一个逻辑流的开流请求，即中继要的形状。 */
export interface StreamOpening {
  readonly endpoint: string
  readonly payload: unknown
  readonly signal: AbortSignal
}

export function callThrough<T>(callee: (...args: unknown[]) => T, values: Record<string, unknown>): T {
  const names = parameterNamesOf(callee)
  const positional = positionalArguments(names?.length ?? callee.length, values)
  if (names === undefined) return callee(...positional)
  return callee(...names.map((name, index) => (Object.hasOwn(values, name) ? values[name] : positional[index])))
}

/**
 * Gateway 自有端点拿到的 uplink：它一打开就交回迭代器，载具项被丢弃而非读取
 * （types.d.ts:81）。必须是真实的 AsyncIterable —— 网关在开流时会对它调用
 * `return()`。
 */
function emptyUplink(): AsyncIterable<unknown> {
  return (async function* () {})()
}

/**
 * opener 声明的形参名，读不出时为 `undefined`。源码按原样读取，而不是按书写
 * 意图：Cordis 把服务成员改写成带尾逗号的多行形参表，所以空的尾巴是正常的，
 * 不能当作名字（`async open(\n  endpoint,\n  payload,\n)`）。
 */
export function parameterNamesOf(opener: (...args: unknown[]) => unknown): string[] | undefined {
  const source = Function.prototype.toString.call(opener)
  const open = source.indexOf('(')
  const close = source.indexOf(')', open + 1)
  if (open === -1 || close === -1) return undefined
  const names = source
    .slice(open + 1, close)
    .split(',')
    .map((parameter) => parameter.trim().split(/[=\s]/u)[0]!)
    .filter((name) => name.length > 0)
  const readable = names.length > 0 && names.every((name) => /^[A-Za-z_$][\w$]*$/u.test(name))
  return readable ? names : undefined
}

/**
 * 按位置实参，对应迄今见过的形参表：两者中取消信号都在最后，历来各版本也都
 * 放在最后；已知名字之后的实参（`control`）保持 `undefined`，由网关自备。
 * 按 arity 猜测是可以接受的，因为另一条路是流完全打不开。
 */
function positionalArguments(arity: number, values: Record<string, unknown>): unknown[] {
  if (arity >= 5) return [values.endpoint, values.payload, values.uplink, values.peer, values.signal]
  return [values.endpoint, values.payload, values.signal]
}

/**
 * 按形参名调用 DSH 宿主，而不是按位置。位置是内部细节，不是契约：网关的私有
 * 成员可能在我们关心的那个参数之前新增一个参数。名字能挺过这种变化，也能挺过
 * Cordis 对服务成员的多行改写。
 *
 * 形参表读不出（bind、native）时回退到按位置，未知名字取它的位置槽。必需的实参有两个
 * —— `signal`（取消）与 `peer`（身份，R11）—— 它们在不同版本的槽位也不同，所以都必须
 * 由调用方真给值：位置兜底只保证「按迄今见过的形参表摆放」。
 */

/**
 * 上游 opener 的形参表会随运行时版本变长、槽位也会移动：`uplink` / `peer` 都曾被插在
 * `signal` 前面，按位置传的取消信号因此落进 uplink 槽、真正的 `signal` 成了 `undefined`，
 * 网关内部 `AbortSignal.any([undefined, ...])` 当场抛错 —— 中继每一代都死在建流那一步。
 * 形参名是唯一稳的锚点，实参一律按名填（{@link callThrough}）。
 *
 * 自 0.2 起 `peer` 也是**必需**实参（`types.d.ts` 原文：required, never defaulted），且宿主
 * 在开流时会解引用它（`assertPeerLive` 读 `peer.signal.aborted`）—— 它必须由调用方真给一个
 * Peer，`undefined` 不再是可接受的进程内载具（R11）。
 */
export function openStreamThrough(
  opener: (...args: unknown[]) => Promise<AsyncIterable<unknown>>,
  opening: StreamOpening,
  receiver?: unknown,
): Promise<AsyncIterable<unknown>> {
  return callThrough(opener, {
    endpoint: opening.endpoint,
    payload: opening.payload,
    uplink: emptyUplink(),
    peer: opening.peer,
    signal: opening.signal,
  }, receiver)
}

/**
 * 一个 Peer 的会话（上游 `PeerScope`）窄到开流用得着的程度。中继**不消费**它 ——
 * 只是把它递给宿主，所以这里只声明宿主会读的那三个字段。
 */
export interface PeerScopeLike {
  /** 调用者身份，创建时就固定，线上字段设不了它。 */
  readonly principal: { readonly kind: string }
  /** Peer 被销毁时中止；以该身份开的流随之结束。 */
  readonly signal: AbortSignal
  /** 是否允许开 forwarded-event 流（`$events` 要求 `answer`）。 */
  readonly interactions: 'answer' | 'none'
}

/** 一个逻辑流的开流请求，即中继要的形状。 */
export interface StreamOpening {
  readonly endpoint: string
  readonly payload: unknown
  /** 流所代表的身份。见 {@link openStreamThrough} 的第二段。 */
  readonly peer: PeerScopeLike
  readonly signal: AbortSignal
}

/**
 * 调用宿主的一个成员 —— 按形参名摆实参，并**带着它的接收者**。
 *
 * `receiver` 不是可有可无的一半：宿主的成员大多是**实例方法**，取出引用就与实例脱钩，
 * `this` 在方法体里成了 `undefined`，第一处 `this.xxx` 当场读出
 * `Cannot read properties of undefined`。真机 2026-10-15 的现场正是如此 —— `dispatchRpc`
 * 的第一句 `this.remoteEventClients.get(...)`，于是**手机的每一条应答都进不去上游**，
 * 而它看起来还「成功」（R11）。箭头函数字段（如 `wireStream.open`）不受影响，但没有任何
 * 理由省掉接收者。
 */
export function callThrough<T>(
  callee: (...args: unknown[]) => T,
  values: Record<string, unknown>,
  receiver?: unknown,
): T {
  const names = parameterNamesOf(callee)
  const positional = positionalArguments(names?.length ?? callee.length, values)
  const args = names === undefined
    ? positional
    : names.map((name, index) => (Object.hasOwn(values, name) ? values[name] : positional[index]))
  return callee.apply(receiver, args)
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

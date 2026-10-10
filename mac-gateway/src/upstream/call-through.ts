/**
 * Calls into the DSH host **by parameter name**, not position. Positions are internal
 * detail, not contract: the gateway's private members may grow a parameter ahead of the
 * one we care about. Names survive that, and Cordis's multi-line
 * rewrite of service members.
 *
 * An unreadable parameter list (bound, native) falls back to positions, and an unknown name takes
 * its positional slot — garbage for that argument, never for `signal`, the one argument a stream
 * cannot be opened without.
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
    // `undefined` is the operator's own in-process carrier (types.d.ts:83).
    peer: undefined,
    signal: opening.signal,
  })
}

/** One logical stream's opening, as the relay asks for it. */
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
 * The uplink a Gateway-owned endpoint gets: it hands its iterator back as soon as it opens,
 * so carrier items are dropped rather than read (types.d.ts:81). It must be a real
 * AsyncIterable — the gateway calls `return()` on it while opening.
 */
function emptyUplink(): AsyncIterable<unknown> {
  return (async function* () {})()
}

/**
 * The opener's declared parameter names, or `undefined` when none can be read. The source is
 * read as-is, not as written: Cordis rewrites service members to multi-line parameter lists
 * with a trailing comma, so an empty tail is normal and must not pass for a name
 * (`async open(\n  endpoint,\n  payload,\n)`).
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
 * Arguments by position, for the parameter lists seen so far: cancellation is last in both,
 * which is where every build has put it; anything past the known names (`control`) stays
 * `undefined`, the gateway supplying its own. Guessing by arity is acceptable only because
 * the alternative is failing to open the stream at all.
 */
function positionalArguments(arity: number, values: Record<string, unknown>): unknown[] {
  if (arity >= 5) return [values.endpoint, values.payload, values.uplink, values.peer, values.signal]
  return [values.endpoint, values.payload, values.signal]
}

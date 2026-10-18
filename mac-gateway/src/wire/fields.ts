/**
 * 线上载荷里单个字段的规则 —— 一个 `unknown` 能不能当作某种值用。
 *
 * 消费者（两处及以上，故点名）：`wire/mux.ts`、`wire/model.ts`、`wire/write.ts`
 * 与 `protocol/rpc.ts`。前三个是 codec，第四个判的是同一批 op 的信封字段 ——
 * 所以这三条是「两端共守的字段规则」，属于 `wire/` 的编解码范畴，不是新类别。
 *
 * **这里只判值的形状，不判领域语义。** `isNotFound` / `isPlausiblePairingCode`
 * 那类认识特定错误码或业务格式的判断不进这个文件 —— 它们跟着协议语义变，
 * 而本文件的三条只跟着「什么叫合法值」变。
 *
 * **每条都必须有 codec 在用**：它是 codec 之间重复的零件被提出来共享的结果，
 * 不是「以后可能会用」的收纳盒。没有任何 codec 引用时，判据会红
 * （`structure.test.ts` 的 `WIRE_FIELD_GUARDS`）。
 */

/**
 * 非空字符串，否则无。
 *
 * 「空」只指长度为 0：纯空白**算合法**。要拒纯空白的那一处自己做（`sessionPromptOf`
 * 对 `text` 单独要求 trim 后非空）—— 那条规则只服务一个字段，提上来会让所有
 * 调用点为它付利息。
 */
export function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

/** 安全整数（含 0、含负数），否则无。 */
export function isIntegral(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value)
}

/**
 * 正整数，否则无。
 *
 * 交出类型谓词而不是布尔：「能不能当循环上界」的调用点收窄之后就不必再写
 * `as number`。布尔语境的调用（`if (isPositiveInteger(x))`）照样成立。
 */
export function isPositiveInteger(value: unknown): value is number {
  return isIntegral(value) && value > 0
}

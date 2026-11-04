/**
 * 装配边界：上游失败的词汇 —— 四个纯谓词。
 *
 * 它们与运行时自身的错误类做结构匹配 —— `isDSHRemoteError` 与 `code` ——
 * 因为本模块位于安装树之外，拿不到宿主的错误类。
 *
 * 只共享谓词；一个失败变成哪个协议码由各调用方决定（流与写路径对
 * not-found 的折叠方式不同）。
 *
 * 住在装配边界而不是 `wire/`：它们描述的是**上游**失败，手机端从来看不见
 * 这类词汇；而它们服务的读者是要决定错误码的那一层，正是这里。
 */

/** 该错误是否表示「已存储，但本运行时不解读它」。 */
export function isUnreadable(error: unknown): boolean {
  const name = (error as { name?: unknown } | null)?.name
  return name === 'SessionFormatUnsupportedError' || name === 'SessionPersistenceCorruptionError'
}

/** 该错误是否属于宿主的远程失败（结构化检查）。 */
export function isRemoteError(error: unknown): error is { code: string } {
  return typeof error === 'object' && error !== null
    && (error as { isDSHRemoteError?: unknown }).isDSHRemoteError === true
    && typeof (error as { code?: unknown }).code === 'string'
}

/**
 * 该远程失败是否表示「所指之物不存在」：任意命名空间下的 `/not-found`
 * 后缀，包括尚未认识的命名空间 —— 缺东西，不是服务端故障。
 */
export function isNotFound(error: unknown): boolean {
  return isRemoteError(error) && error.code.endsWith('/not-found')
}

/** 人类可读的原因，只用于拒绝消息。 */
export function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

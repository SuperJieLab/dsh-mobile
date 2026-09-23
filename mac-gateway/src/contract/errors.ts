/**
 * Upstream failures, read one way: two pure predicates, once copied into the
 * HTTP contract, the stream adapter, and the write adapter.
 *
 * They match the runtime's own error classes structurally — `isDSHRemoteError`
 * and `code` — because this module lives outside the installation.
 *
 * Only the predicates are shared; which protocol code a failure becomes stays
 * with each caller (the stream and write paths fold a not-found differently).
 */

/** Whether an error means "stored, but this runtime will not interpret it". */
export function isUnreadable(error: unknown): boolean {
  const name = (error as { name?: unknown } | null)?.name
  return name === 'SessionFormatUnsupportedError' || name === 'SessionPersistenceCorruptionError'
}

/** Whether an error is one of the host's remote failures (structural check). */
export function isRemoteError(error: unknown): error is { code: string } {
  return typeof error === 'object' && error !== null
    && (error as { isDSHRemoteError?: unknown }).isDSHRemoteError === true
    && typeof (error as { code?: unknown }).code === 'string'
}

/**
 * Whether a remote failure means "what you named is not there": the
 * `/not-found` suffix in **any** namespace, even one we do not know yet —
 * a missing thing, not a server fault.
 */
export function isNotFound(error: unknown): boolean {
  return isRemoteError(error) && error.code.endsWith('/not-found')
}

/** A human-readable reason, for the refusal message only. */
export function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

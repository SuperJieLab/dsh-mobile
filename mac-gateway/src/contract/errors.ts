/**
 * Upstream failures, read one way.
 *
 * Three copies of these two predicates had accumulated (the HTTP contract, the
 * stream adapter, the write adapter). The cost was not the lines: each copy
 * decides *which protocol code an upstream failure becomes*, so a new error
 * class added in one place would silently keep being `internal-error` in the
 * others — the HTTP path and the stream path answering differently for the
 * same failure. Pure functions, like everything else in this directory.
 *
 * The names are the runtime's own error classes. `isDSHRemoteError` / `code`
 * are what a `@deepseek-ai/dsh-*` remote failure carries structurally; this
 * module cannot import the host's classes (it lives outside the installation).
 *
 * Only the *predicates* are shared. Which protocol code a failure becomes
 * stays with each caller — the stream path and the write path fold a not-found
 * into different codes on purpose.
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
 * Whether a remote failure means "what you named is not there" — matched by the
 * `/not-found` suffix in **any** namespace (`session/not-found`,
 * `agent/not-found`, …), so a namespace we do not know about yet still reads as
 * a missing thing rather than a server fault.
 */
export function isNotFound(error: unknown): boolean {
  return isRemoteError(error) && error.code.endsWith('/not-found')
}

/** A human-readable reason, for the refusal message only. */
export function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

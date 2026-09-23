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
 */

/** Whether an error means "stored, but this runtime will not interpret it". */
export function isUnreadable(error: unknown): boolean {
  const name = (error as { name?: unknown } | null)?.name
  return name === 'SessionFormatUnsupportedError' || name === 'SessionPersistenceCorruptionError'
}

/** A human-readable reason, for the refusal message only. */
export function describeError(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

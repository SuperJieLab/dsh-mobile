/**
 * The write seam (M5): parsing and replay bookkeeping for the two write ops —
 * docs/dev/plans/M5-remote-intervention.md §四 (as amended by 实施期修正 11).
 *
 * Write payloads are validated strictly, unlike the read paths' lenient
 * defaults: on a read, a malformed cursor degrades to a redundant payload; on a
 * write, a malformed decision silently executed is a remote command run on a
 * guess. So every malformed write is refused with `invalid-request` rather than
 * normalized (Plan §3.3 决定 8).
 *
 * The replay table makes retries safe (W1): a client that re-sends after a
 * lost reply gets the first outcome again, never a second delivery. The table
 * lives for the process lifetime — long enough for the seconds-scale retry
 * window a lost reply implies, and cleared by a restart, which is harmless
 * because the log's `approval/decided` audit is the truth a client reconciles
 * against anyway (Plan §3.3 决定 3).
 */

/** A validated `approval-answer` message. */
export interface ApprovalAnswerMessage {
  /**
   * The `$events` waterfall frame's `eventId` this answer is about — the id
   * the `approval-request` frame the phone saw carried (实施期修正 11: the
   * projected request payload has no audit id, so the waterfall's own eventId
   * is the only end-to-end address).
   */
  eventId: string
  /** The client's choice; mapped to the upstream outcome vocabulary on delivery. */
  decision: 'allow' | 'deny'
  /** Client-minted idempotency key. Retries with the same key replay the first outcome. */
  answerId: string
}

/**
 * Parse and validate one `approval-answer` payload, or `undefined` when the
 * message cannot be an answer at all. Strict on purpose — see the module note.
 */
export function approvalAnswerOf(message: Record<string, unknown>): ApprovalAnswerMessage | undefined {
  const eventId = nonEmptyString(message.eventId)
  const decision = message.decision === 'allow' || message.decision === 'deny' ? message.decision : undefined
  const answerId = nonEmptyString(message.answerId)
  if (eventId === undefined || decision === undefined || answerId === undefined) return undefined
  return { eventId, decision, answerId }
}

/** A validated `session-prompt` message. */
export interface SessionPromptMessage {
  /** Target session. */
  sessionId: string
  /** Prompt text; empty or whitespace-only cannot become a prompt upstream. */
  text: string
  /** Client-minted idempotency key, passed upstream as the prompt `requestId`. */
  promptId: string
}

/**
 * Parse and validate one `session-prompt` payload, or `undefined`. `sessionId`
 * is *not* validated here: the read paths already map a malformed session id to
 * `unknown-session` ("it can never name a session, the remedy is identical"),
 * and the write path keeps that convention rather than splitting it.
 */
export function sessionPromptOf(message: Record<string, unknown>): SessionPromptMessage | undefined {
  const sessionId = nonEmptyString(message.sessionId)
  const text = typeof message.text === 'string' ? message.text : undefined
  const promptId = nonEmptyString(message.promptId)
  if (sessionId === undefined || promptId === undefined || text === undefined || text.trim() === '') {
    return undefined
  }
  return { sessionId, text, promptId }
}

/** The data source the two write ops are written against — the write seam's only dependency. */
export interface WritePort {
  /**
   * Deliver one answer to the pending approval, or report that no pending
   * approval answers to that id (already consumed, cancelled, or never asked).
   */
  answerApproval(answer: ApprovalAnswerMessage): Promise<'delivered' | 'unknown-approval'>
  /**
   * Admit one prompt into the session's agent inbox, or report that the session
   * does not exist. Any other upstream failure is the caller's `internal-error`.
   */
  promptSession(prompt: SessionPromptMessage): Promise<'accepted' | 'unknown-session'>
}

/**
 * Remember the first outcome per idempotency key and replay it forever after.
 *
 * `produce` runs at most once per key — that is the whole point: the side
 * effect it stands for (delivering an answer, admitting a prompt) happens once
 * even when the client retries.
 */
export class ReplayTable<V> {
  readonly #entries = new Map<string, V>()

  remember(key: string, produce: () => V): { value: V; fresh: boolean } {
    const existing = this.#entries.get(key)
    if (existing !== undefined) return { value: existing, fresh: false }
    const value = produce()
    this.#entries.set(key, value)
    return { value, fresh: true }
  }
}

/** Map the client's two-button vocabulary onto the upstream outcome vocabulary. */
export function outcomeOfDecision(decision: 'allow' | 'deny'): 'allowed-once' | 'rejected' {
  return decision === 'allow' ? 'allowed-once' : 'rejected'
}

/** A non-empty string, or nothing. */
function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

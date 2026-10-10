/**
 * mac-gateway — the Mac-side DSH plugin for dsh-mobile: assembly only. The
 * protocol lives in `contract/`, the phone-facing transports in `remote/`, and
 * every host-facing port factory in `upstream/faces.ts` — this file wires them
 * together and owns the listener's lifetime (docs/dev/protocol.md,
 * docs/dev/plans/R1-gateway-layout.md).
 *
 * The list path (v2) is zero-I/O — headers plus a host-kept projection, never a
 * log — and its four services are declared in `inject`: without them the fiber
 * stays pending, the right failure for a gateway that cannot read sessions
 * (docs/dev/protocol.md §4.1).
 *
 * Imports are Node builtins plus our own modules only; cordis is type-only, as
 * bare specifiers do not resolve outside the dsh installation.
 */
import type { Context } from '@deepseek-ai/cordis'
import { DEFAULT_LIMITS, type Limits, type SessionPort } from './contract/rpc.ts'
import { createSessionPort, type PersistenceLike } from './upstream/sessions.ts'
import { attachStreamHandler } from './remote/ws.ts'
import { createRpcListener } from './remote/http.ts'
import { CredentialVault, DEFAULT_CREDENTIALS_PATH } from './remote/credentials.ts'
import { broadcasterOver, gatewayOver, listSourceOver, modelChannelOver, modelSelectionSourceOver, streamSourceOver, writePortOver } from './upstream/faces.ts'
import { ApprovalRelay } from './upstream/write.ts'
import { createLogger, LogModule } from './log.ts'

const log = createLogger(LogModule.main)

/** Display metadata used by dsh diagnostics. */
export const name = 'mac-gateway'

/**
 * Services this plugin requires before it starts;
 * cordis holds the fiber until they are available (see the module comment).
 */
export const inject = [
  // The read paths (snapshot / page) go straight to the stored log.
  'sessionPersistence',
  // The list path: records (headers + liveness), projections, and what is running.
  'sessionQuery',
  'sessionProjections',
  'sessionProjectionCache',
  'sessions',
  'agents',
  // The follow stream (M2): pump the controller's follow to the WS channel.
  // Only present in the web-app bundle — spec §8.5 B5 records what that costs.
  'sessionController',
  // The approval relay (M5): the gateway's `$events` stream is
  // how a remote client receives and answers approval waterfall requests.
  'typertGateway',
]

/** Plugin config, supplied by the owning patch row. */
export interface Config {
  /** Bind address. `0.0.0.0` reaches the LAN; `127.0.0.1` is loopback only. @default '0.0.0.0' */
  host?: string
  /** Bind port. @default 3081 */
  port?: number
  /** Most events one `snapshot` reply may carry. Config so the caps are observable end
   * to end (docs/dev/protocol.md §五). @default 500 */
  maxDeltaEvents?: number
  /** Soft ceiling on one reply's serialized `events`, in bytes. @default 1048576 */
  maxDeltaBytes?: number
  /** Where the credentials file lives; overridable so assembly smoke tests never touch
   * the real home. @default '~/.dsh/dsh-mobile/credentials.json' */
  credentialsPath?: string
  /** Pre-pair the vault with this device token (tests only) — production pairing goes
   * through the pairing code. */
  deviceTokenSeed?: string
}

/** M0 全接口绑定的兜底值；M8 起生产经 config.host 改绑 tailnet 地址（100.64.0.1）。 */
const DEFAULT_HOST = '0.0.0.0'

/** Deliberately not 3080 — that is the dsh web profile's own port. */
const DEFAULT_PORT = 3081

/**
 * Cordis calls this with the plugin's context and the config from its tree row. Host
 * and port are config, not constants, so switching the reachability scheme stays a
 * one-line patch edit — the §3.2 reversibility claim needs the bind address to stay
 * uncompiled.
 */
export function apply(ctx: Context, config: Config = {}): void {
  const host = config.host ?? DEFAULT_HOST
  const port = config.port ?? DEFAULT_PORT
  const sessionPort: SessionPort = createSessionPort(
    ctx.sessionPersistence as unknown as PersistenceLike,
    listSourceOver(ctx),
    modelSelectionSourceOver(ctx),
  )
  // Caps are configuration, not constants: they exist to be lowered until a
  // chunked read is observable, which is exactly how they are verified.
  const limits: Limits = {
    maxDeltaEvents: config.maxDeltaEvents ?? DEFAULT_LIMITS.maxDeltaEvents,
    maxDeltaBytes: config.maxDeltaBytes ?? DEFAULT_LIMITS.maxDeltaBytes,
  }

  // The vault owns the three tickets (docs/dev/plans/M4-identity-credentials.md §4.2).
  // `pair` / `refresh` bypass the gate — they carry their own credential.
  const vault = new CredentialVault(config.credentialsPath ?? DEFAULT_CREDENTIALS_PATH)
  if (config.deviceTokenSeed !== undefined) {
    // Tests only: pre-pair without walking through the pairing code.
    vault.seedDeviceToken(config.deviceTokenSeed)
  }
  log.info(`pairing code (valid 10 min, one-shot): ${vault.pairingCode()}`)

  // The write channel (M5): the relay bridges `approval-answer` to the gateway's
  // `$events` stream (a host-side waterfall listener cannot receive remote answers —
  // api-remotes parks them until a remote client speaks); the pump forwards
  // `session-prompt` through the controller's
  // own door (docs/dev/plans/M5-remote-intervention.md §四).
  const relayLifetime = new AbortController()
  const approvalFace = broadcasterOver()
  const relay = new ApprovalRelay(gatewayOver(ctx), approvalFace)
  relay.start(relayLifetime.signal)
  const writePort = writePortOver(ctx, relay)
  // The model channel (M7): declared-face calls into the same controller the relay
  // and the pump use; absent service must say so at assembly, not on first tap.
  const modelPort = modelChannelOver(ctx)

  log.info('plugin loaded — M7 build, auth on both channels, write + model channels on')

  ctx.effect(() => {
    const server = createRpcListener({ sessionPort, limits, vault, writePort, modelPort })

    // The stream channel shares the listener: same port, `POST /rpc` for one-way
    // calls, `/rpc/stream` upgrade gated like any request (M4): no live access token, no 101.
    const broadcaster = attachStreamHandler(server, streamSourceOver(ctx), vault, {
      // A freshly connected phone gets the reconciliation frame (the ids of every
      // standing question), then a replay of each — so it can drop forwarded cards
      // whose `cancel` fired while it was offline: an absent id is authoritative.
      onClientConnected: (send) => {
        const held = relay.held()
        if (!relay.ready) {
          // No live `$events` identity, so the held set proves nothing: a `stale`
          // sync tells the client to keep its cards rather than prune against a lying list.
          send({ type: 'approval', payload: { kind: 'sync', eventIds: [], callIds: [], stale: true } })
          return
        }
        send({
          type: 'approval',
          payload: {
            kind: 'sync',
            eventIds: held.map(h => h.eventId),
            // callIds ride along so audit-rebuilt cards (asked − decided in the log)
            // reconcile against what the gateway still holds: a dangling asked
            // (host died mid-ask) must not resurrect.
            callIds: held.flatMap(h => h.callId === undefined ? [] : [h.callId]),
          },
        })
        for (const heldItem of held) {
          send({ type: 'approval', payload: { kind: 'request', eventId: heldItem.eventId, toolName: heldItem.toolName, ...(heldItem.callId === undefined ? {} : { callId: heldItem.callId }), ...(heldItem.reason === undefined ? {} : { reason: heldItem.reason }) } })
        }
      },
    })
    approvalFace.connect((frame) => broadcaster.broadcast(frame as Parameters<typeof broadcaster.broadcast>[0]))

    // Our logger (console underneath) rather than ctx.logger: in non-TTY runs
    // `ctx.logger.info` emitted nothing (dsh's own startup line too), and an
    // invisible bind failure beats a non-idiomatic log; TTY-gating is unverified
    // (docs/dev/plans/M0-reachability-spike.md §5.1).
    server.on('error', (error) => {
      log.error(`listener error: ${String(error)}`)
    })

    server.listen(port, host, () => {
      log.info(`listening on http://${host}:${port}`)
    })

    return () => {
      relayLifetime.abort()
      // close() alone leaves idle keep-alive sockets open since Node 19, keeping
      // the port occupied across a live patch reload.
      server.closeAllConnections()
      server.close()
    }
  }, 'mac-gateway.listener')
}

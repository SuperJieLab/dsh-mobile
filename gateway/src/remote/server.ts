/**
 * 连接集合：upgrade 的分发，以及那条**进程内唯一**的登记表（谁连着、哪条流是谁的）。
 *
 * 存活范围是**整个进程**。集合自己不做协议协商（那是 `connection.ts` 的事），
 * 也不写字节（写出与守卫是 `egress.ts` 的事）—— 它只回答「现在有谁连着」，
 * 并把同一个 `IdentityRegistry` 交给需要判归属的那一侧。
 *
 * 这一层不产生协议码 —— 握手拒绝用的是 HTTP 状态行（404 / 401 / 400 / 409），那是传输
 * 自己的词汇，不是协议信封。身份类的 `unauthenticated` / `invalid-pairing-code`
 * 在 `http.ts` 的闸门旁，同属 HTTP 401 一族。
 */

import type { Server } from 'node:http'
import { handleUpgrade, type StreamOptions } from './connection.ts'
import type { FollowSource } from '../ports/follow.ts'
import type { Identity } from '../protocol/auth.ts'
import { IdentityRegistry } from './identity-registry.ts'

/**
 * 把流协议挂上插件自己的监听器：集合自己只持有 socket 与计数，协商与后续的
 * socket 交给 `connection.ts` —— 这样「集合的失败」与「一条连接的失败」是两回事。
 *
 * `gate` 是认证闸门，在应答握手之前于升级时检查一次 —— 无有效 access token，就没有 101。
 * token 过期后连接继续存活；重新认证发生在下一次连接，不在流中途。
 */
export function attachStreamHandler(
  server: Server,
  source: FollowSource,
  gate: { authenticate(authorizationHeader: string | undefined): Identity | undefined },
  options: StreamOptions = {},
): { clientCount(): number; registry: IdentityRegistry } {
  // 登记表由装配层**传进来**（`options.registry`），不在这里 new：它同时要交给
  // 一元调用的闸门（`remote/http.ts` 用它判归属），两处各 new 一个就永远判不出主人。
  // 缺省 new 一个只为「普通流测试不关心归属」这一档 —— 生产装配必须显式给（`index.ts`）。
  const registry = options.registry ?? new IdentityRegistry()
  server.on('upgrade', (request, socket, head) => {
    void handleUpgrade(request, socket, head, source, gate, registry, options)
  })
  return {
    // 名额就是 socket 数：一张表管两件事，读数也就只有一处。
    clientCount: () => registry.size,
    registry,
  }
}

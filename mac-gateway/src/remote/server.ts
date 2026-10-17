/**
 * 连接集合：upgrade 的分发、持有每一条已认证的 socket、向它们广播。
 *
 * 存活范围是**整个进程**。集合自己不做协议协商（那是 `connection.ts` 的事），
 * 也不为每帧重复编码（一次编码、写 N 次；写出与守卫是 `egress.ts` 的事）——
 * 它只回答「现在有谁连着」。
 *
 * 广播时某个 socket 已死不影响其余：写之前检查 `destroyed`，一个死连接只是被跳过。
 *
 * 这一层不产生协议码 —— 握手拒绝用的是 HTTP 状态行（404 / 401 / 400），那是传输
 * 自己的词汇，不是协议信封。身份类的 `unauthenticated` / `invalid-pairing-code`
 * 在 `http.ts` 的闸门旁，同属 HTTP 401 一族（见 `ISSUES` A13 的分类）。
 */

import type { Duplex } from 'node:stream'
import type { Server } from 'node:http'
import type { MuxServerFrame } from '../wire/mux.ts'
import { encodeServerFrame } from '../wire/mux.ts'
import { handleUpgrade, type StreamOptions } from './connection.ts'
import type { FollowSource } from '../ports/follow.ts'
import { encodeTextFrame } from './frames.ts'
import { write } from './egress.ts'

/** approval 中继向已连接手机推送所用的接口。 */
export interface Broadcaster {
  /** 向每个存活且已认证的客户端发送一条连接级帧。 */
  broadcast(frame: MuxServerFrame): void
  /** 当前接入的客户端数 —— 资源采样读它。 */
  clientCount(): number
}

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
  gate: { authenticate(authorizationHeader: string | undefined): boolean },
  options: StreamOptions = {},
): Broadcaster {
  const clients = new Set<Duplex>()
  server.on('upgrade', (request, socket, head) => {
    void handleUpgrade(request, socket, head, source, gate, clients, options)
  })
  return {
    broadcast(frame) {
      const text = encodeTextFrame(encodeServerFrame(frame))
      for (const socket of clients) write(socket, text)
    },
    clientCount: () => clients.size,
  }
}

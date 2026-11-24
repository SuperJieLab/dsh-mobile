/**
 * 登记表：**一个身份只许一条 socket**，一条流归属于一个身份。
 *
 * 这是「一条流归属于一个对象」的机制半边。它只回答三个问题 ——
 * 这个身份现在有没有占着一条 socket、这条 socket 属于谁、这条流是谁的 ——
 * 不认识协议，不认识审批，也不判「谁能答」（那在 `protocol/rpc.ts` 的
 * `remoteEventResultValue` 里，它只看一个 `ownerOf`）。
 *
 * 为什么住在 `remote/`：它管的是 socket 与流的对应关系，是传输层的机制。
 * `protocol/` 一侧只看见窄接口 `StreamOwners`（声明在 `protocol/rpc.ts`）——
 * 接口归消费方，机制留在这里。
 *
 * 为什么不建 `Peer` 类：上游的 Peer 带着 `Context` / `signal` / `Principal` /
 * `interactions`，能让流挂在它上面一起 abort。我们这里的「对象」只有一条 socket
 * 和一格 id，两张 `Map` 就够；造一个只有两个字段的类叫 `Peer`，只会让人以为
 * 我们也有上游那套生命周期。
 */

import type { Duplex } from 'node:stream'
import type { Identity } from '../protocol/auth.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.ws)

interface StreamOwner {
  readonly socket: Duplex
  readonly identityId: string
}

export class IdentityRegistry {
  /** 身份 → 它占着的那条 socket。**这张表就是「一身份一条 socket」的全部**。 */
  readonly #sockets = new Map<string, Duplex>()
  /** socket → 身份。反查用：开流时只拿得到 socket。 */
  readonly #identities = new Map<Duplex, string>()
  /** clientId → 它的主人。每条 `$events` 流一格。 */
  readonly #streams = new Map<string, StreamOwner>()

  /**
   * 占一个名额。已被同一身份占着时返回 `false`（调用方回 409）。
   *
   * **必须保持同步** —— 不要改成 `async`。两条 upgrade 同时到、都读到「没有」
   * 再各自登记，就会出现两条属于同一身份的 socket，而 409 形同虚设。Node 的单线程
   * 让「读-判-写」天然原子，前提是中间没有 `await`。
   */
  claim(identity: Identity, socket: Duplex): boolean {
    if (this.#sockets.has(identity.id)) return false
    this.#sockets.set(identity.id, socket)
    this.#identities.set(socket, identity.id)
    return true
  }

  /**
   * 还名额，并**连带清掉这条 socket 名下的流**。
   *
   * 只还名额不清归属，会让一条已经不存在的流继续「有个主人」：它上面挂着的
   * `clientId` 此后每次应答都判成越权，而日志里没有任何线索说明那条流早就不在了。
   */
  release(socket: Duplex): void {
    const identityId = this.#identities.get(socket)
    if (identityId === undefined) return
    this.#identities.delete(socket)
    if (this.#sockets.get(identityId) === socket) this.#sockets.delete(identityId)
    for (const [clientId, owner] of this.#streams) {
      if (owner.socket === socket) this.#streams.delete(clientId)
    }
  }

  /**
   * 这条 socket 属于谁；未登记（或已释放）时为 `undefined`。
   *
   * 生产里的消费者只有 {@link openStream} 自己（它要从 socket 反查身份）；导出是为了让
   * 「谁是这条连接的主人」在判据里读得到 —— 那是这一层唯一能被外部观测的状态。
   */
  identityOf(socket: Duplex): string | undefined {
    return this.#identities.get(socket)
  }

  /**
   * 记下「这条流是谁的」。开流时与 `ready` **同一个同步块**里调用 ——
   * 中间有窗口的话，那段时间里到达的应答无法归属。
   *
   * **每条流只该调一次**：换代只换上游那条流，`clientId` 与 socket 都不变，重入没有意义
   * （`pumpEvents` 因此把它放在 `announce` 外面）。这里把重入当成异常 —— 同一 `clientId`
   * 被两条流复用在生产上不可能（`randomUUID()` 现造），真出现时旧的归属就丢了，那件事
   * 要能被看见。反过来说：**换代不该走到这条 warn**，走到了就是把正常路径报成了异常。
   */
  openStream(clientId: string, socket: Duplex): void {
    const identityId = this.#identities.get(socket)
    if (identityId === undefined) {
      // 未归属的 socket 不该有流。静默不登记会让应答判不出主人，所以至少说一声。
      log.warn('a stream opened on a socket with no identity — not registered', { client: clientId })
      return
    }
    if (this.#streams.has(clientId)) {
      log.warn('the same clientId opened twice — the earlier stream loses its owner', { client: clientId })
    }
    this.#streams.set(clientId, { socket, identityId })
  }

  /** 这条流的主人（身份 id）；没有这条流时为 `undefined`。 */
  ownerOf(clientId: string): string | undefined {
    return this.#streams.get(clientId)?.identityId
  }

  /** 流关掉：它的 `clientId` 从此答不了任何问题。 */
  closeStream(clientId: string): void {
    this.#streams.delete(clientId)
  }

  /** 此刻占着名额的 socket 数（资源采样读它，观测量与 `clients.size` 同义）。 */
  get size(): number {
    return this.#sockets.size
  }
}

import type { MuxApprovalHeld } from '../wire/mux.ts'

/**
 * 一条待答调用，不含 `kind`。
 *
 * 暂存与发出去的**必须是同一份字段集合** —— 抄一遍的话，「暂存里有、帧上没有」这种
 * 漏字段在评审里看不出来（两份声明相隔几十行、长得几乎一样），而症状只有重放之后才出现。
 */
export type HeldApproval = MuxApprovalHeld

/**
 * 事件流需要的审批事实。
 *
 * 四个成员回答四个问题，缺一不可：
 *   - `ready`：现在能不能给出一份可信的当前集合（不能就该拒绝开流，而不是给一份旧的）
 *   - `held`：现在有哪些（每一条 `ready` 之后要重放的内容）
 *   - `onHeld` / `onCancelled`：变了怎么知道
 *
 * 两种变化各一个回调、不合成一个带 `kind` 的事件：`kind` 是**帧**的概念，端口这一层
 * 不该出现它 —— 于是「一个 kind 的帧形状只有一个作者」在类型上就成立，不用靠判据追。
 *
 * 端口由消费方（流泵）定义、实现方（中继）遵循 —— 与 `StreamPort` 同一个方向：
 * 于是类型依赖单向，中继不认识帧，流泵不认识宿主。
 */
export interface ApprovalSource {
  readonly ready: boolean
  held(): HeldApproval[]
  /** 一条待答调用进来了（或同 `eventId` 的更新）。返回退订函数。 */
  onHeld(listener: (held: HeldApproval) => void): () => void
  /** 一条被撤回了（别处先答、或上游撤回）。返回退订函数。 */
  onCancelled(listener: (eventId: string) => void): () => void
}

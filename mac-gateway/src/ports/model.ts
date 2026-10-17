/**
 * 装配边界：模型 op 所依赖的能力，由宿主适配层实现。
 *
 * `ModelSelectOutcome` 里的两个码是**上游的拒绝词汇**（原码透传，语义是
 * 「换一个模型或修凭证」），与协议错误码同形但不同源 —— 它们住在这里，因为
 * 决定「怎么翻成协议码」的是协议层，不是传输层。
 */

import type { ModelCatalog, ModelSelectMessage, ModelSelection } from '../wire/model.ts'

/** 一次 select 的结果：规范化后的选择，或上游的拒绝。 */
export type ModelSelectOutcome =
  | { ok: true; selected: ModelSelection }
  | { ok: false; code: 'unknown-session' | 'session/model-unavailable'; message: string }

/** 模型 op 所依赖的数据源 —— 契约的唯一依赖。 */
export interface ModelPort {
  /** 当前宿主代的目录。失败时抛错（`internal-error`）。 */
  catalog(): Promise<ModelCatalog>
  /** 安装一条会话级选择。上游的拒绝作为结果返回。 */
  select(request: ModelSelectMessage): Promise<ModelSelectOutcome>
}

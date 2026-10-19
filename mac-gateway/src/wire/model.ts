/**
 * 两端共守的模型形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/GatewayProtocol.swift`）—— 改字段那边必须同改。
 *
 * 这里**只有形状与 `model-select` 的解析**。目录怎么从宿主读住在 `upstream/model.ts`，
 * 选择怎么安装、上游的拒绝怎么翻成协议码住在 `protocol/rpc.ts` 的 `modelSelect` ——
 * 那些是服务端的事，手机端看不见。
 *
 * 上游的规范化形状原样转发：校验与规范化都在控制器的门后，契约只转达门后
 * 给出的答复。
 */
import { nonEmptyString } from './fields.ts'

/** 一条规范化后的模型选择，用上游自己的词汇。 */
export interface ModelSelection {
  provider: string
  model: string
  reasoningEffort?: string
}

/**
 * 宿主的模型目录：按 provider 分组的模型、部署默认值，以及逐个
 * provider 隔离的失败。`routableProviders` 被适配器剥掉 —— 客户端用不上。
 */
export interface ModelCatalog {
  /** 部署默认值，部署有默认时存在。 */
  default?: ModelSelection
  /** 至少含一个模型的 provider 分组。 */
  groups: readonly ModelGroup[]
  /** 枚举失败的 provider，各记一条，绝不拖垮整个目录。 */
  failures: readonly ModelFailure[]
}

export interface ModelGroup {
  id: string
  name: string
  models: readonly { id: string; name: string }[]
}

export interface ModelFailure {
  id: string
  name: string
  message: string
}

/** 校验通过的 `model-select` 消息。 */
export interface ModelSelectMessage {
  sessionId: string
  provider: string
  model: string
  reasoningEffort?: string
}

/**
 * 解析并校验一条 `model-select` 载荷，完全不像选择时返回 `undefined`。
 * 刻意从严 —— 写路径规则：畸形选择被静默执行，会让下一轮指向一个没人选过的
 * 模型。`sessionId` 不在此校验 —— 读路径已把畸形 id 映射到 `unknown-session`，
 * 写路径沿用该约定。
 */
export function modelSelectRequestOf(message: Record<string, unknown>): ModelSelectMessage | undefined {
  const sessionId = nonEmptyString(message.sessionId)
  const provider = nonEmptyString(message.provider)
  const model = nonEmptyString(message.model)
  // 存在但为空对齐上游自身 schema（`z.string().min(1)`）：在此拒绝，
  // 绝不静默当作缺省 —— 写载荷不会变成与客户端所发不同的另一个请求。
  const reasoningEffort = message.reasoningEffort === undefined ? undefined : nonEmptyString(message.reasoningEffort)
  if (sessionId === undefined || provider === undefined || model === undefined) return undefined
  if (message.reasoningEffort !== undefined && reasoningEffort === undefined) return undefined
  return {
    sessionId,
    provider,
    model,
    ...reasoningEffort === undefined ? {} : { reasoningEffort },
  }
}


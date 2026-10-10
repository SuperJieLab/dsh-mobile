/**
 * 模型契约 (M7)：会话级模型选择的单条 op ——
 * dev/plans/M7-model-selection.md §四。`model-catalog` 是读 op，端口
 * 缺失时像写通道未接线一样拒绝（生产装配必接线，此拒绝在生产不可达）。
 *
 * 端口是契约的唯一依赖；用 fake 让测试摆脱运行时与网络。上游的规范化形状
 * 原样转发 —— 校验与规范化都在控制器的门后（决定 3），契约只转达门后
 * 给出的答复。
 */

/** 一条规范化后的模型选择，用上游自己的词汇（决定 3）。 */
export interface ModelSelection {
  provider: string
  model: string
  reasoningEffort?: string
}

/**
 * 宿主的模型目录（决定 6）：按 provider 分组的模型、部署默认值，以及逐个
 * provider 隔离的失败。`routableProviders` 被适配器剥掉 —— 客户端用不上
 * （§四 契约段）。
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

/** 校验通过的 `model-select` 消息（决定 3 的请求形状）。 */
export interface ModelSelectMessage {
  sessionId: string
  provider: string
  model: string
  reasoningEffort?: string
}

/**
 * 解析并校验一条 `model-select` 载荷，完全不像选择时返回 `undefined`。
 * 刻意从严 —— 写路径规则（protocol.md §六 `invalid-request`）：畸形选择被
 * 静默执行，会让下一轮指向一个没人选过的模型。`sessionId` 不在此校验 ——
 * 读路径已把畸形 id 映射到 `unknown-session`，写路径沿用该约定
 * （contract/write-channel.ts 同款）。
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

/** 非空字符串，否则无。 */
function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

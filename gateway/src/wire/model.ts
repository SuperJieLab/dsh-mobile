/**
 * 两端共守的模型形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/ModelMessages.swift`）—— 改字段那边必须同改。
 *
 * 这里**只有形状与请求容器的判型**。目录怎么从宿主取住在 `upstream/faces.ts` 的
 * `modelChannelOver`（它只转发），选择怎么安装、上游的拒绝怎么翻成协议码住在
 * `protocol/rpc.ts` 的 `modelSelectOf` —— 那些是服务端的事，手机端看不见。
 *
 * 上游的形状原样转发：校验与规范化都在控制器的门后，契约只转达门后给出的答复。
 * 所以 {@link ModelCatalog} 的键集合就是上游的键集合 —— 少一格就是被裁过，
 * 而少一格不会让任何一处编译失败。
 */
import { nonEmptyString, requestContainerOf } from './fields.ts'

/** 一条规范化后的模型选择，用上游自己的词汇。 */
export interface ModelSelection {
  provider: string
  model: string
  reasoningEffort?: string
}

/**
 * 宿主的模型目录：按 provider 分组的模型、部署默认值、可路由的 provider，
 * 以及逐个 provider 隔离的失败。**四格都与上游同名同形，网关不裁。**
 */
export interface ModelCatalog {
  /** 部署默认值。上游声明为必填 —— 建目录时总会定一个。 */
  default: ModelSelection
  /** 至少有一个可用模型的路由名。客户端用不上，但它属于上游形状，裁掉就是第二份。 */
  routableProviders: readonly string[]
  /** 至少含一个模型的 provider 分组。 */
  groups: readonly ModelGroup[]
  /** 枚举失败的 provider，各记一条，绝不拖垮整个目录。 */
  failures: readonly ModelFailure[]
}

export interface ModelGroup {
  id: string
  name: string
  models: readonly {
    id: string
    name: string
    /** 该模型声明的推理等级；缺席 = 它不暴露等级选择。 */
    reasoning?: ModelReasoning
  }[]
}

/**
 * 一个模型能选的推理等级。`efforts` 是对象数组（每项有 id 与显示名），不是 id 串 ——
 * 手机端按这个形状逐字段解码。
 */
export interface ModelReasoning {
  efforts: readonly ModelReasoningEffort[]
  /** 不指定时宿主用哪一档；缺席 = 由适配器自己的默认值决定。 */
  defaultEffort?: string
}

export interface ModelReasoningEffort {
  id: string
  name: string
  description?: string
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
 * 解析并校验一条 `model-select` 载荷（**含宿主的 `request` 容器**），完全不像选择时
 * 返回 `undefined`。刻意从严 —— 写路径规则：畸形选择被静默执行，会让下一轮指向一个
 * 没人选过的模型。`sessionId` 不在此校验存在性 —— 读路径已把畸形 id 映射到
 * `unknown-session`，写路径沿用该约定。
 *
 * @param args - `payload.args`；宿主的形参是 `request`，所以容器键名也是它。
 */
export function modelSelectRequestOf(args: Record<string, unknown>): ModelSelectMessage | undefined {
  const message = requestContainerOf(args)
  if (message === undefined) return undefined
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


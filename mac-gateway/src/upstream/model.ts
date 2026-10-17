/**
 * 模型适配器：唯一知道 session controller 提供模型选择的模块。它基于
 * controller 的**声明**切面实现契约的 `ModelPort` —— `selectModel` / `modelCatalog`
 * 是公开 Remote 方法（`dsh-api-session-controller/lib/types/index.js:137-138`），
 * 因此与审批中继不同，这里不需要私有切面逃生口；漂移风险在形参*列表*上，
 * 下面的签名检查盯着它（形参名变了要出声，绝不静默按位置喂垃圾）。
 *
 * 校验与归一化归上游所有：它的门回答什么 —— 归一化的 `selected`，
 * 或类型化拒答 —— 就转达什么，绝不在此重新推导。第二份「哪个模型合法」
 * 的拷贝正是两个真理的来源。
 */

import { isRemoteError, isNotFound } from '../ports/errors.ts'
import type { ModelCatalog, ModelSelection, ModelSelectMessage } from '../wire/model.ts'
import type { ModelPort, ModelSelectOutcome } from '../ports/model.ts'
import { createLogger, LogModule } from '../log.ts'

const log = createLogger(LogModule.model)

/**
 * 本适配器调用的 session controller 部分。签名与运行时逐字一致 ——
 * 与真实切面不同的 fake 会让漂移通过所有测试。
 */
export interface ModelControllerLike {
  selectModel(request: {
    sessionId: string
    provider: string
    model: string
    reasoningEffort?: string
  }): Promise<{ selected: ModelSelection }>
  modelCatalog(): Promise<Record<string, unknown>>
}

/** 基于 controller 的声明切面构建契约的模型端口。 */
export function modelPortOver(controller: ModelControllerLike): ModelPort {
  // 组装期签名检查：下面的调用按位置传 request 对象，只要形参表与运行时
  // 一致就是精确的。变化在这里触发 —— 启动时，而不是第一次点击时。
  if (!parameterListIs(controller.selectModel, ['request'])) {
    warnSignature('selectModel', controller.selectModel)
  }
  if (!parameterListIs(controller.modelCatalog, [])) {
    warnSignature('modelCatalog', controller.modelCatalog)
  }

  return {
    async catalog(): Promise<ModelCatalog> {
      const raw = (await controller.modelCatalog()) as {
        default?: unknown
        groups?: unknown
        failures?: unknown
      }
      return {
        ...raw.default === undefined || raw.default === null ? {} : { default: raw.default as ModelCatalog['default'] },
        groups: (raw.groups ?? []) as ModelCatalog['groups'],
        failures: (raw.failures ?? []) as ModelCatalog['failures'],
      }
    },

    async select(request: ModelSelectMessage): Promise<ModelSelectOutcome> {
      try {
        const answer = (await controller.selectModel({ ...request })) as { selected: ModelSelection }
        return { ok: true, selected: { ...answer.selected } }
      } catch (error) {
        if (isNotFound(error)) {
          return { ok: false, code: 'unknown-session', message: String((error as { message?: unknown }).message ?? error) }
        }
        if (isRemoteError(error)) {
          return { ok: false, code: error.code as 'session/model-unavailable', message: String((error as { message?: unknown }).message ?? error) }
        }
        throw error
      }
    },
  }
}

/** 可调用对象的形参表是否恰好读出 `expected` 这些名字。 */
function parameterListIs(fn: (...args: never[]) => unknown, expected: readonly string[]): boolean {
  const source = Function.prototype.toString.call(fn)
  const open = source.indexOf('(')
  const close = source.indexOf(')', open + 1)
  if (open === -1 || close === -1) return false // bound 或 native：读不出
  const names = source
    .slice(open + 1, close)
    .split(',')
    .map(name => name.trim())
    .filter(name => name.length > 0)
  return names.length === expected.length && expected.every((name, index) => names[index] === name)
}

/** 漂移告警：点名漂移者并展示切面，修复只需一次阅读。 */
function warnSignature(member: string, fn: (...args: never[]) => unknown): void {
  log.warn(
    `model adapter: ${member}'s parameter list differs from the runtime signature this build was written against; reads: ${Function.prototype.toString.call(fn).slice(0, 160)}`,
  )
}

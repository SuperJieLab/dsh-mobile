/**
 * 模型契约的形状与解析在 `wire/model.ts`，端口在 `ports/model.ts`。本文件只做重导出，
 * 让下游的 import 路径不必一次改完 —— 期2 搬算法时统一改成直连。
 */

export { modelSelectRequestOf } from '../wire/model.ts'
export type {
  ModelCatalog,
  ModelFailure,
  ModelGroup,
  ModelSelectMessage,
  ModelSelection,
} from '../wire/model.ts'
export type { ModelPort, ModelSelectOutcome } from '../ports/model.ts'

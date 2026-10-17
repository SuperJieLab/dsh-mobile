/**
 * 上游失败的谓词已搬到装配边界 `ports/errors.ts`（它们服务的是决定错误码的那一层）。
 * 这里只重导出，让下游的 import 路径不必一次改完 —— 期2 搬算法时统一改成直连。
 */

export { describeError, isNotFound, isRemoteError, isUnreadable } from '../ports/errors.ts'

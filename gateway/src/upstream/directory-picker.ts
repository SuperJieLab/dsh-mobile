/**
 * DSH 适配器：唯一知道目录选择器读面的模块。
 *
 * 只做一件事：把宿主的 `directoryPickerController.list(path, signal)` 递给端口。
 * 路径归一化、可见性、截断都在宿主那一侧 —— 我们再算一遍就是第二份规则。
 */

import type { DirectoryPort } from '../ports/directory.ts'
import type { HostContext } from './faces.ts'

/** 本适配器用到的宿主切面。 */
interface DirectoryPickerFace {
  list(path: string | undefined, signal: AbortSignal): Promise<unknown>
}

/**
 * 目录读面。宿主没有这个切面时抛错，由协议层折成 `internal-error` —— 不给一份
 * 「看起来有、其实不知道」的列表。
 */
export function directoryPickerOver(ctx: HostContext): DirectoryPort {
  return {
    async list(path, signal) {
      const controller = ctx.directoryPickerController as unknown as Partial<DirectoryPickerFace> | undefined
      if (typeof controller?.list !== 'function') {
        throw new Error('directoryPickerController has no list face — directoryPicker/list cannot be served')
      }
      return await controller.list(path, signal)
    },
  }
}

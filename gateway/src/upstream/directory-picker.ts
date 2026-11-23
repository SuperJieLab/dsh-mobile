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
 *
 * **`directoryPickerController` 不在 `inject` 里**，所以这里必须经 `ctx.reflect.get`
 * 取，不能写成 `ctx.directoryPickerController`：cordis 对没注入的服务属性**一读就抛**
 * （`cannot get property "directoryPickerController" without inject`），而这一行在每次
 * 请求里跑 —— 抛出来就是一条 `internal-error`，手机看到的是「目录读不了」，日志里那句
 * 与「宿主的目录选择器缺席」长得一样。
 *
 * 它也不该进 `inject`：目录浏览器是扩展能力（headless 宿主没有原生选择器），注入它等于
 * 让整个网关等一个可选插件，缺席时 fiber 永远 pending。所以每次调用重新取 —— 插件晚于
 * 网关就绪时，下一次请求自己接上。
 */
export function directoryPickerOver(ctx: HostContext): DirectoryPort {
  return {
    async list(path, signal) {
      const controller = ctx.reflect.get('directoryPickerController') as
        | Partial<DirectoryPickerFace>
        | undefined
      if (typeof controller?.list !== 'function') {
        throw new Error('directoryPickerController has no list face — directoryPicker/list cannot be served')
      }
      return await controller.list(path, signal)
    },
  }
}

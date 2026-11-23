/**
 * 装配边界：列一层宿主目录（手机端的目录浏览器要的那一面）。
 *
 * 与 `workspace.ts` 分开：组是宿主的注册表，目录是宿主的文件系统 —— 两个控制器、
 * 两个变化原因。合成一个接口会让「组变了」与「文件系统变了」共用一条依赖。
 *
 * 手机端不知道这个接口存在：它是网关内部两层的约定，不是线上形状。
 */

/** 协议层所依赖的目录读面，用 fake 让测试摆脱文件系统。 */
export interface DirectoryPort {
  /**
   * 列一层目录；`path` 缺省时由宿主决定（它的 home）。
   *
   * 应答原样转发（`DirectoryListing` 的五个键）—— 网关不归一化路径、不裁行。
   * 读不到（不存在 / 无权限）由宿主抛，调用方折成 `internal-error`。
   */
  list(path: string | undefined, signal: AbortSignal): Promise<unknown>
}

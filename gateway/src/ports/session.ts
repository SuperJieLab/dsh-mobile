/**
 * 装配边界：协议层要的「读会话」能力，由宿主适配层实现。
 *
 * 这些接口属于**消费方**（协议层），所以住在装配边界而不是传输层或适配层 ——
 * 后者若持有它们，适配层就得反过来 import 传输层去取一个类型。接口放这里，
 * 两边都只依赖它。
 *
 * 手机端不知道这些接口存在：它们是网关内部两层的约定，不是线上形状。
 *
 * **两个成员都是转发**：`list` 递给宿主的 `session/list`，`page` 递给
 * `session/page`。网关不再自己读日志 —— 一读就得把「哪些记录算一页」的规则抄一份，
 * 而抄的那份在宿主改规则时不会红。
 */

/**
 * 协议层所依赖的数据源 —— 契约的唯一依赖；用 fake 让测试摆脱运行时、
 * 文件系统与网络。
 */
export interface SessionPort {
  /**
   * 宿主的 `session/list`：**原样转发**，网关不排序、不裁剪、不改名。
   *
   * 返回类型是 `unknown` 而不是一份我们自己声明的行类型 —— 那是这条判据的要点：
   * 形状由宿主决定，网关一旦声明它，就会在宿主加字段时静默地变成两份。
   *
   * @param request - `_request` 的内层；`{cursor?}`。
   * @param signal - 取消。HTTP 断开目前不接到这里（见方案「明确不做」）。
   */
  list(request: Readonly<Record<string, unknown>>, signal: AbortSignal): Promise<unknown>
  /**
   * 宿主的 `session/page`：**原样转发**，网关不重切窗口、不改水位、不补默认值。
   *
   * 请求与应答都是上游 `SessionPageRequest` / `SessionPage` 的形状（请求四个水位键，
   * 应答 `{records, hasMore, cursor}`）—— 这里声明 `unknown`，理由同 `list`：
   * 声明一份就等于多一份会在宿主加字段时静默过期的形状。
   *
   * @param request - `request` 容器的内层（宿主的形参就叫 `request`）。
   * @param signal - 取消，同 `list`。
   */
  page(request: Readonly<Record<string, unknown>>, signal: AbortSignal): Promise<unknown>
}

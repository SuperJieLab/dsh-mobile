/**
 * 装配边界：协议层要的「读一条实时订阅」的能力。
 *
 * 接口归**消费方**（协议层），所以住在这里而不是传输层：宿主适配层要的是这个
 * 接口，若它长在传输层，适配层就得反过来 import 传输层 —— 依赖方向就反了。
 *
 * 两个类型同处一个端口：一个是能力声明（`FollowSource`），一个是**上游给出的
 * 帧形状**（`UpstreamFollowFrame`）。后者就是线上形状 —— 网关不组装打开帧，
 * 手机看见的 `snapshot` 与宿主发出的是同一份，所以它复用 `wire/mux.ts` 的
 * `FollowValue`，不另立一套。
 */

import type { FollowRequest } from '../wire/endpoints.ts'
import type { FollowValue } from '../wire/mux.ts'
import type { ProjectionBaseline } from '../wire/rpc.ts'

/**
 * 泵所用的宿主窄面，在此声明是因为各服务的真实类型在 dsh 安装树之外
 * 无法解析。follow 流与占用读数作为一次注入到达，因为两者出自同一宿主。
 */
export interface FollowSource {
  /**
   * 直呼宿主的 `follow(request, signal)` —— 入参是上游的 `SessionFollowRequest`，
   * 网关一个字段都不改（不补默认窗口、不重算 `maxMessages`）。
   */
  follow(request: FollowRequest, signal: AbortSignal): AsyncIterable<UpstreamFollowFrame>

  /**
   * **全部会话**的投影切取 —— control 流用它建表，再按会话算增量。
   *
   * 与上游 `SessionControlController.baseline()` 同形（`ctx.sessions.list()` 逐个
   * `snapshot(session)`）。不是「按会话查」：control 是 Host-wide 的一条流，
   * 客户端自己挑它关心的那个会话。
   *
   * 缺席（宿主没接）是诚实的：control 泵据此回一条 error，不猜。
   */
  controlBaseline?(): Readonly<Record<string, ProjectionBaseline>>
}

/**
 * 上游 follow 流的一帧：打开的 `snapshot`（原样上线），随后是同包裹的 `event` 帧，
 * 再后是无 cursor 的 `assistant-stream` 帧。
 *
 * 与 `wire/mux.ts` 的 `FollowValue` 是**同一个类型**而不是两份等价声明：两条流之间
 * 隔着一层转发，形状一旦分开写，宿主加一格而线上少一格时不会编译失败。
 */
export type UpstreamFollowFrame = FollowValue

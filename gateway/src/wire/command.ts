/**
 * 两端共守的命令形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/GatewayProtocol.swift`）—— 改字段那边必须同改。
 *
 * **线上收一整行文本，不拆名字与参数。** 语法只由宿主定义（`parseCommand` 的正则），
 * 客户端拆一次就等于实现第二份语法：上游放宽或收紧分隔规则时，这份拷贝不会编译失败，
 * 只会在某个参数上静默错位。
 *
 * 这里**只有形状与载荷解析**。宿主怎么列、怎么执行住在 `upstream/command.ts`。
 */

import { nonEmptyString } from './fields.ts'

/**
 * 宿主的一条命令。名字与说明原样转发 —— 手机端按它们渲染列表，不重排、不改写。
 *
 * `inputHint` 是宿主给的参数占位提示（如 `<preset>`）；缺席 = 这条命令不带自由参数。
 */
export interface CommandInfo {
  name: string
  description: string
  inputHint?: string
}

/** 校验通过的 `command-execute` 消息。 */
export interface CommandExecuteMessage {
  sessionId: string
  /** 完整的一行，含前导斜杠与参数。原样交给宿主。 */
  line: string
}

/**
 * 解析并校验一条 `command-execute` 载荷，不像一条命令行时返回 `undefined`。
 *
 * 刻意从严（写路径纪律）：一行畸形的命令被静默执行，等于在 Mac 上跑了一条没人打算跑的东西。
 * **前导斜杠与「非空」在这里就判** —— 上游的 `parseCommand` 也会拒，但拒的理由会变成
 * `unknown-command`（「没有这条命令」），而真正的原因是「这根本不是命令」；两者的补救不同。
 */
export function commandExecuteRequestOf(message: Record<string, unknown>): CommandExecuteMessage | undefined {
  const sessionId = nonEmptyString(message.sessionId)
  const line = nonEmptyString(message.line)
  if (sessionId === undefined || line === undefined) return undefined
  // 必须是 `/名字...`：前导斜杠后接一个小写字母（与上游 parseCommand 的起点一致），
  // 但不在这里校验名字的其余字符 —— 那是宿主的语法，我们只挡「明显不是命令行」的输入。
  if (!/^\/[a-z]/u.test(line)) return undefined
  return { sessionId, line }
}

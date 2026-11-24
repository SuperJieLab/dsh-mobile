/**
 * 两端共守的命令形状与它的编解码。手机端有一份对应定义
 * （`ios/Sources/Core/Gateway/Wire/CommandMessages.swift`）—— 改字段那边必须同改。
 *
 * **线上的名字与容器照抄宿主的远端方法**：`commands/list(agent)` 与
 * `commands/execute(agent, line, submittedAttachments)`。宿主的参数叫 `agent`，
 * 线上那一格叫 `agentId`（宿主把 `Agent` 序列化成 id）。
 *
 * **线上收一整行文本，不拆名字与参数。** 语法只由宿主定义（`parseCommand` 的正则），
 * 客户端拆一次就等于实现第二份语法：上游放宽或收紧分隔规则时，这份拷贝不会编译失败，
 * 只会在某个参数上静默错位。
 *
 * 这里**只有形状与载荷解析**。宿主怎么列、怎么执行住在 `upstream/command.ts`。
 */

import { nonEmptyString } from './fields.ts'

/** 一条命令的参数提示 —— 与上游 `CommandInputDescriptor` 同形。 */
export interface CommandInputDescriptor {
  /** 自由输入前的占位提示（如 `<preset>`）。 */
  hint: string
  /** 它能不能带附件。缺席或 `false` = 带附件的调用会被拒。 */
  attachments?: boolean
}

/**
 * 宿主的一条命令 —— 与上游 `CommandDescriptor` 同形，原样转发。
 *
 * 平铺成 `{name, description, inputHint}` 会丢掉 `definitionId` 与 `attachments`：
 * 前者是客户端按身份而不是按名字做行为时唯一能用的键，后者决定输入框要不要收附件。
 */
export interface CommandDescriptor {
  /** 插件持有的稳定身份；不按身份做行为的命令没有这一格。 */
  definitionId?: string
  /** 小写命令名，不带前导斜杠。 */
  name: string
  /** 给人读的一句话。 */
  description: string
  /** 可选自由输入；缺席 = 这条命令不带自由参数。 */
  input?: CommandInputDescriptor
}

/** 校验通过的 `command-execute` 消息。 */
export interface CommandExecuteMessage {
  agentId: string
  /** 完整的一行，含前导斜杠与参数。原样交给宿主。 */
  line: string
}

/**
 * 解析并校验一条 `command-execute` 载荷，不像一条命令行时返回 `undefined`。
 *
 * 刻意从严（写路径纪律）：一行畸形的命令被静默执行，等于在 Mac 上跑了一条没人打算跑的东西。
 * **前导斜杠与「非空」在这里就判** —— 上游的 `parseCommand` 也会拒，但拒的理由会变成
 * `unknown-command`（「没有这条命令」），而真正的原因是「这根本不是命令」；两者的补救不同。
 *
 * `submittedAttachments` 只接受**缺席或空数组**：附件还没接。非空时拒 ——
 * 静默丢掉附件会让「附件没生效」看起来像命令自己的问题。
 */
export function commandExecuteRequestOf(message: Record<string, unknown>): CommandExecuteMessage | undefined {
  const agentId = nonEmptyString(message.agentId)
  const line = nonEmptyString(message.line)
  if (agentId === undefined || line === undefined) return undefined
  if (!isEmptyAttachments(message.submittedAttachments)) return undefined
  // 必须是 `/名字...`：前导斜杠后接一个小写字母（与上游 parseCommand 的起点一致），
  // 但不在这里校验名字的其余字符 —— 那是宿主的语法，我们只挡「明显不是命令行」的输入。
  if (!/^\/[a-z]/u.test(line)) return undefined
  return { agentId, line }
}

/** 附件这一格：缺席与空数组等价（客户端总是发空数组），其余一律不算。 */
function isEmptyAttachments(value: unknown): boolean {
  return value === undefined || (Array.isArray(value) && value.length === 0)
}

/**
 * 端点名单只有一个真源：**表**（`ENDPOINTS`）决定哪个名字有人处理，数组是它的对外投影。
 *
 * 两处分家的症状很具体，而且两种方向都不好查：
 * - 名字进了数组、没进表 —— 契约会按数组要求写一节，而那条端点实际回 404；红的是别人。
 * - 名字进了表、没进数组 —— 服务端能处理，但没人知道有这个能力，客户端不会发。
 *
 * `wire/` 不许认识 `protocol/`（`structure.test.ts` 的两条目录判据封死了这个方向），
 * 所以数组**不能**由表派生；一致性只能靠这一条判据钉住。
 *
 * 类型系统只挡一个方向：`ENDPOINTS` 是 `Partial<Record<UnaryEndpointName, …>>`，
 * 允许某个名字没有处理器 —— 「表少一个」在类型上合法，所以必须有这条判据。
 *
 * Run: node --test tests/protocol/endpoint-names.test.ts
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'

import { UNARY_ENDPOINT_NAMES } from '../../src/wire/unary.ts'
import { registeredEndpointNames } from '../../src/protocol/unary-endpoints.ts'

test('端点名单与端点表是同一批名字', () => {
  // 两边都按 `string[]` 比：数组那侧的元素类型是 `UnaryEndpointName`，直接拿去
  // `includes` 一个 `string` 会撞上「子类型数组不接受父类型实参」。
  const listed: string[] = [...UNARY_ENDPOINT_NAMES].sort()
  const registered: string[] = [...registeredEndpointNames()].sort()

  // 活性锚：两处都空时下面的 deepEqual 恒真，而「恒真」在报告里跟「全绿」长得一样。
  assert.ok(registered.length > 5, `表里只登记了 ${registered.length} 个端点 —— 先怀疑读错了表`)

  const onlyListed = listed.filter((name) => !registered.includes(name))
  const onlyRegistered = registered.filter((name) => !listed.includes(name))
  assert.deepEqual(
    { onlyListed, onlyRegistered },
    { onlyListed: [], onlyRegistered: [] },
    `两份名单差了：只在数组 [${onlyListed.join(', ')}]；只在表 [${onlyRegistered.join(', ')}]`,
  )
})

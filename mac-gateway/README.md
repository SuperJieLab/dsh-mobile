# mac-gateway

Mac 侧的 DSH 插件：把本机 dsh 进程里的会话状态暴露给手机。

**下文所有路径都相对 `src/`。**

这个包有两个「入口」，它们回答的不是同一个问题 —— 混在一起谈会看不清：

| 入口 | 回答什么 | 在哪 |
|---|---|---|
| **业务承接** | 手机的一条请求被谁接住 | `remote/http.ts`（一元）、`remote/server.ts`（流） |
| 插件生效 | dsh 加载器什么时候把这个包挂进插件树 | `cordis.patch.yml`（见本文件末尾） |

本文件按「更常被问到的」顺序写：先业务链路，插件生命周期放最后。

## 一、手机的一条请求怎么走

同一个端口上并行两条通道。它们只在两处汇合：**同一道认证闸门**、**同一批 ports**。

### 一元：`POST /rpc`

```
index.ts             apply(ctx) 里 createRpcListener(...)
  ↓
remote/http.ts       createServer(respond) —— server 是这里创建的
  ↓
                     respond()
                       · 路径不是 /rpc → 存活文本（/）或 404
                       · 方法不是 POST → 405
                       · 读 body：>1 MiB → 413；不是 JSON → 400
  ↓
                     两个凭据类 op 绕过闸门（凭据在体内而不是头部）
                       op === pair | refresh → handleAuthOp → vault.pair / refresh
  ↓
                     vault.authenticate(authorization) → 无票即 401 + 协议信封
  ↓
protocol/rpc.ts      handle(message, ports, now, limits) —— switch 按 op 分派
  ↓
                     各 op 自己的处理器 → SessionPort / WritePort / ModelPort
  ↓
upstream/            ports 的实现：读宿主投影、读日志、把写泵到宿主
```

### 流：`/rpc/stream` 升级

```
index.ts              apply(ctx) 里 attachStreamHandler(server, ...)
  ↓
remote/server.ts      server.on('upgrade') —— 它**不创建** server，只挂监听；
  ↓                     并把每条已认证的 socket 存进集合，供广播
remote/connection.ts  handleUpgrade(...) —— 与一元同一道闸门（无票即无 101）
  ↓                     101 之后进入成帧循环 + 心跳
remote/stream.ts      onClientText(...) —— 每条流的 open / cancel
  ↓                     泵：把 FollowSource 的事件折成 mux 帧
remote/egress.ts      send(...) —— 帧的出口：编码 + 写 + 记一行 perf
```

`egress.ts` 只服务流通道（`connection.ts` 与 `stream.ts` 都经它）；一元那条直接写响应体，不经过帧编码。**这就是为什么握手字节（101/404/401/400）与心跳 ping 不在 `egress.ts` 里** —— 它们不是 mux 帧。

## 二、目录各是什么

不在这里复述 —— 五个目录的承诺（「改它要不要动手机端」）写在 `index.ts` 的头注释里，那里是唯一的出处，一处一写。

## 三、怎么跑

```
npm run typecheck      # tsc --noEmit，覆盖 src + tests + tools
npm test               # 先跑 typecheck，再跑 node --test
```

`npm test` 的门禁顺序是有意的：`node --test` 只剥类型不校验，所以类型闸门必须排在前面。类型错时用例一行都不跑 —— 红的闸门，不是判据。

## 四、插件什么时候被加载（次要）

dsh 安装这个包时读 `cordis.patch.yml`，把 `./src/index.ts` 作为一行插进插件树。`name` 是**相对 patch 文件**的路径，加载器会在 patch 文件旁边锚定它 —— 所以这个文件里没有绝对路径，包被装到哪里都对。

`index.ts` 的 `inject` 声明九个宿主服务；缺任何一个，cordis 会扣住 fiber（表现为「起来了但没监听」），这正是「读不了会话就不该说自己活着」的形态。

# dsh-mobile-gateway

运行 dsh 那一侧的插件：把本机 dsh 的会话状态经两条通道暴露给 dsh-mobile 客户端，并承担客户端的鉴权。

下文路径默认相对 `src/`；带 `src/` 前缀的写法相对包根。

本包有两个入口，回答的不是同一个问题：

| 入口 | 回答的问题 | 位置 |
|---|---|---|
| 业务承接 | 手机的一条请求由谁接住 | `remote/http.ts`（一元）、`remote/server.ts`（流） |
| 插件加载 | dsh 的加载器何时把这个包挂进插件树 | `cordis.patch.yml` |

## 请求路径

两条通道共用同一个端口，只在两处汇合：同一道认证闸门、同一批 ports。

### 一元通道 `POST /rpc`

```
src/index.ts          apply(ctx) 里 createRpcListener(...)
  ↓
remote/http.ts        createServer(respond) —— server 在这里创建
  ↓
                      respond()
                        · 路径不是 /rpc → 存活文本（/）或 404
                        · 方法不是 POST → 405
                        · 读 body：超过 1 MiB → 413；不是 JSON → 400
  ↓
                      两个凭据类操作绕过闸门（凭据在请求体内，不在头部）
                        op === pair | refresh → handleAuthOp → vault.pair / refresh
  ↓
                      vault.authenticate(authorization) → 无票即 401 + 协议信封
  ↓
protocol/rpc.ts       handle(message, …ports) —— switch 按 op 分派
  ↓
                      各 op 的处理器 → SessionPort / WritePort / ModelPort / CommandPort
  ↓
upstream/             ports 的实现：读宿主投影、读日志、把写泵到宿主、把命令整行交给宿主
```

### 流通道 `/rpc/stream`

```
src/index.ts          apply(ctx) 里 attachStreamHandler(server, ...)
  ↓
remote/server.ts      server.on('upgrade') —— 不创建 server，只挂监听；
  ↓                    并把每条已认证的 socket 收进集合，供广播使用
remote/connection.ts  handleUpgrade(...) —— 与一元通道同一道闸门（无票即无 101）
  ↓                     101 之后进入成帧循环与心跳
remote/stream.ts      onClientText(...) —— 每条流的 open / cancel
  ↓                     泵：把 FollowSource 的事件折成 mux 帧
remote/egress.ts      send(...) —— 帧的出口：编码、写入、记录一行 perf
```

`remote/egress.ts` 只服务流通道；一元通道直接写响应体，不经帧编码。报文握手（101 / 404 / 401 / 400）与心跳 ping 不属于 mux 帧，因此不在该文件中。

### 命令通道

命令走一元通道：`command-catalog` 列出某会话当下可用的命令，`command-execute` 把整行原文交给宿主 —— 语法归宿主，网关不拆分名字与参数。应答仅表示已受理；结果经流上的 `command/run`、`command/done` 到达，按 `commandId` 配对。

## 目录职责

各目录的承诺（改动是否需要同步手机端）写在 `src/index.ts` 的头注释里，此处不再重复。

## 安装

dsh 的插件安装器接受的 spec 与 `pnpm add` 一致，共四类：

| 形式 | 示例 |
|---|---|
| 注册表包名 | `dsh-mobile-gateway`、`dsh-mobile-gateway@0.1.0` |
| git | `github:owner/repo`、`git+https://…`、`https://host/owner/repo` |
| tarball | `https://…/dsh-mobile-gateway-0.1.0.tgz`，也接受本地 `.tgz` |
| 本地路径 | `/abs/path/to/gateway`、`link:/abs/path/to/gateway` |

两条安装路径，差别只在「装的是哪一份」：

| 命令 | profile 里记的是 | 何时用 |
|---|---|---|
| `./install.sh` | `link:` 指向本工作区 | 开发时：改代码即生效；工作区移动或删除后该 profile 失效 |
| `./install.sh --from-release` | latest release 上的 `.tgz` 副本 | 只想用、不想依赖工作区 |

注册表形式要求包可公开发布，git 形式要求仓库根即包根，本包两者都不满足（位于 monorepo 子目录，且 `private: true`）。发布走 tarball：推一个 `v*` tag 时，`.github/workflows/release-gateway.yml` 会跑测试、`npm pack`、建 release 并上传附件。附件名固定为 `dsh-mobile-gateway.tgz`（版本由 URL 的 tag 段表达），因此 `latest/download/` 那个地址永远指向最新一份，不必随版本改。

版本号只有 tag 一个来源，且 iOS 与本包共用同一个数：`version` 必须等于 tag 去掉 `v` 之后的部分，不符则工作流在打包前失败。

## 验证

```
npm run typecheck      # tsc --noEmit，覆盖 src + tests + tools
npm test               # 先跑 typecheck，再跑 node --test
```

门禁顺序是有意的：`node --test` 只剥类型、不做校验，类型闸门必须排在前面。类型出错时用例一行都不会运行。

## 插件加载

dsh 安装本包时读 `cordis.patch.yml`，把 `./src/index.ts` 作为一行插入插件树。`name` 是相对 patch 文件的路径，加载器在 patch 文件旁锚定它，因此文件内不含绝对路径，包被装到何处都成立。

`src/index.ts` 的 `inject` 声明所依赖的宿主服务；缺其中任何一个，cordis 会扣住 fiber —— 表现为进程已启动但没有开始监听。

# dsh-mobile

在 iPhone 上远程用 dsh —— 手机连到跑 dsh 的那台机器，看会话、发消息、批审批。

```
iPhone App  ──Tailscale 虚拟网──▶  网关  ──▶  dsh
```

走 Tailscale 而不是局域网，所以手机和那台机器不在同一个 Wi-Fi 也能用。

## 你需要

| | |
|---|---|
| **一台常开的机器** | 跑 dsh 和网关。Mac / Linux / Windows 都行（只在 macOS 上实测过） |
| **iPhone** | iOS 18.1 或更新 |
| **Tailscale 账号** | 免费额度够用；自建 headscale 也行 |
| **Xcode 16+** | 把 App 装到手机上（没有 TestFlight，只能自己签） |

## 装

### 1. 网关那侧

```bash
git clone https://github.com/SuperJieLab/dsh-mobile.git
cd dsh-mobile
./install.sh
```

`install.sh` 把网关插件注册进 dsh 的 profile，然后告诉你下一步。装完启动：

```bash
npx @deepseek-ai/dsh@alpha web
```

看到这行就是起来了：

```
[mac-gateway] listening on http://0.0.0.0:3081
```

### 2. 手机侧

Xcode 打开 `ios/DshMobile.xcodeproj`，选你的设备，Run。

**装到自己手机上要改两处**，建一个 `ios/Config/Local.xcconfig`：

```
APP_BUNDLE_ID = com.yourname.dshmobile
DEVELOPMENT_TEAM = <你的 Team ID>
```

模板在 `ios/Config/Shared.xcconfig`。不改也能构建，只是 bundle id 是占位的
`com.example.dshmobile`，装不上你的手机。

### 3. 连起来

**① 组网** —— Tailscale 后台生成一个 auth key（`tskey-auth-...`），在 App 的
**设置 → 组网** 里填两项：

- **接入密钥**：那串 `tskey-auth-...`
- **网关地址**：那台机器在 tailnet 里的地址，形如 `http://100.x.y.z:3081`
  （`tailscale ip -4` 能看到。**不是** `192.168.x.x`）

**② 配对** —— 网关启动日志里有 6 位配对码（10 分钟有效），在 **设置 → 身份 → 配对** 里输入。

配好之后回到列表，就能看到那台机器上的会话了。

## 用

| 屏 | 能做什么 |
|---|---|
| **会话列表** | 按工作空间分组；新建会话；顶部显示连接状态 |
| **会话详情** | 看消息流（Markdown、工具调用、过程可折叠）；发消息；遇到审批时出卡片；输入 `/` 弹命令面板；切模型；看用量 |
| **设置 → 组网** | 控制面地址、网关地址、接入密钥 |
| **设置 → 身份** | 配对状态、配对、解除 |
| **设置 → 诊断** | 导出诊断包（日志 + 崩溃 + 性能，可分享）、操作历史（谁改了什么） |

## 截图

> 待补。截图放到 `assets/screenshots/`，我把引用加进来。

| 会话列表 | 会话详情 | 审批 |
|---|---|---|
| _待补_ | _待补_ | _待补_ |

## 已知的边界

- **只能用 Xcode 装** —— 没有 TestFlight，也没有 App Store。
- **免费 Apple ID 签的包 7 天过期**，到期要重新 Run 一次。付费开发者账号不受此限。
- **必须有 Tailscale** —— App 不走局域网直连，网关监听在 tailnet 地址上。
- **一个网关对应一台机器**，但多台手机可以同时连，各自单独配对。
- **只在 macOS 上验证过**。网关代码里没有平台假设（绑 `0.0.0.0`、路径走 `os.homedir()`），
  Linux / Windows 理论上可行，但没实测过。

## 撤销

```bash
./install.sh --revoke    # 撤销所有已配对设备
```

撤销后手机的下一次请求会收到 401，重新配对即可恢复。

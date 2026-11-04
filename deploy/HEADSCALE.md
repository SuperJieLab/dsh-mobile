# HEADSCALE 部署手册（M8 T1）

> **状态（2026-11-04）：暂时不用 —— 当前走官方 Tailscale。**
> 留档不是因为还会用，是因为这里记着踩过的坑（825 天证书上限、DERP 与控制面共端口、
> `curl` 不校验证书时长所以不能拿它当判据、`ca.key` 留本地冷备）。将来真要自建时，
> 这些能省掉一轮重查。**它不在任何自动化路径上**，删掉不影响构建与运行。
>
> M8 跨网承载的控制面搭建手册：在一台有公网 IP 的 VPS 上跑 headscale（自建 Tailscale 协调服务器）+ 内置 DERP + STUN。
> **隐私纪律：本手册与仓库公开，真实值一律不落文件 —— 执行前在终端 `export VPS_IP=<你的VPS公网IP>`，命令全部用 `$VPS_IP` 引用。pre-auth key 只显示一次，直接复制给设备，不经手任何文件。**
> 版本基线：headscale **v0.29.4**（2026-10-08 查证，配置键已对照该版官方示例核实）。证书由同目录 `gen-certs.sh` 生成（自签 CA + 825 天叶子——825 天是 Apple 信任链的上限，见 §9 排障 ①）。

## 0. 端口表（对照 M8 Plan §5.4）

| 端口 | 协议 | 用途 |
|---|---|---|
| 8443 | TCP | headscale 控制面 HTTPS（内置 DERP 复用同端口，路径 `/derp`） |
| 3478 | UDP | STUN（打洞探测） |

避开：443（VLESS 占用）、3081（网关）。注：headscale 内置 DERP 与控制面共用同一 HTTPS 监听，**不需要**单独的 DERP 端口。

## 1. 防火墙与系统准备

```sh
# VPS 上执行（Debian 12）。按你的防火墙工具二选一：
sudo ufw allow 8443/tcp && sudo ufw allow 3478/udp
# 或 nftables / 云厂商安全面板放行同两条
```

## 2. 证书

本机执行（私钥不上 VPS 的那把留本地冷备）：

```sh
cd deploy && VPS_IP=<你的VPS公网IP> ./gen-certs.sh
# 上传三件（ca.key 不传）：
scp tls/ca.crt tls/server.crt tls/server.key <user>@$VPS_IP:/tmp/
```

VPS 上归位：

```sh
mkdir -p /etc/headscale/tls
mv /tmp/{ca.crt,server.crt,server.key} /etc/headscale/tls/
chown -R headscale:headscale /etc/headscale  # 装完 headscale 后执行一次
```

设备信任：`ca.crt` 在 Mac 上双击安装进「系统」钥匙串并设为信任；iPhone 上装描述文件（设置 → 通用 → VPN 与设备管理）后到 关于本机 → 证书信任设置 里开启完全信任。对应 M8 判据链路 1 的「验证书」。

## 3. 安装 headscale

> 版本基线：**v0.29.4**（2026-10-08 查证为最新，本手册配置键已对照该版官方示例核实）。升级前跑下面「查最新」一条确认，若大版本变了需重核配置键。

```sh
# 查最新（升级时用）：
curl -s https://api.github.com/repos/juanfont/headscale/releases/latest | grep tag_name

# 安装（amd64 机器；arm64 机器把两处 amd64 换成 arm64）：
curl -o headscale.deb -L https://github.com/juanfont/headscale/releases/download/v0.29.4/headscale_0.29.4_linux_amd64.deb
dpkg -i headscale.deb && rm headscale.deb
```

机器架构不确定就先跑 `uname -m`：输出 `x86_64` = amd64，`aarch64` = arm64。

## 4. 配置

**不用在远端编辑器里改任何东西** —— 配置模板已随仓库提供（`config-headscale.yaml`，基于 v0.29.4 官方示例裁剪），本地替换占位符后 scp 覆盖即可：

```sh
# 本机执行（deploy/ 下）：
sed "s/__VPS_IP__/$VPS_IP/g" config-headscale.yaml > /tmp/headscale-config.yaml
scp -i <私钥路径> /tmp/headscale-config.yaml <user>@$VPS_IP:/tmp/

# VPS 上执行（/etc 需要 root，普通用户 scp 直传会被拒，故经 /tmp 中转）：
sudo mv /tmp/headscale-config.yaml /etc/headscale/config.yaml
```

模板要点（细节见模板内注释）：`server_url` 与 DERP 的 `ipv4` 用真实 IP；TLS 挂 §2 传上去的叶子证书；DERP 复用 8443（`urls: []` 关官方 DERP map）；`dns.magic_dns: false`（M8 决定 8，直用 100.x IP）。唯一真实值落盘点 = 远端的 `/etc/headscale/config.yaml`。

## 5. 启动

```sh
sudo systemctl enable --now headscale
sudo systemctl status headscale            # 确认 active (running)；日志应出现 0.0.0.0:8443
```

## 6. 建用户、发两把 pre-auth key

```sh
sudo headscale users create dsh
# ⚠️ v0.29 CLI：--user 接的是数字 ID 不是用户名，ID 从 users list 里看（首个用户通常是 1）
sudo headscale users list
# key① → Mac（T2 用），key② → iPhone（T5 用）；--reusable 允许同 key 重装重入，--expiration 给时效
sudo headscale preauthkeys create --user 1 --expiration 24h --reusable
sudo headscale preauthkeys list --user 1
```

key 只在生成时完整显示一次，当场复制进设备；过期重新 generate 即可，不需要重启服务。

## 7. 验证（判据 V1 / V3 前半）

```sh
# 本机或任何位置：
curl -k https://$VPS_IP:8443/health     # → {"status":"pass"}（-k 因为是自签 CA）
# 外网 STUN 可达性（V3 前半；T2 完成后在 Mac 入网后验全）
nc -z -u $VPS_IP 3478
```

V1 通过 = T1 结束。产出物：服务地址 + 两把 key + 本手册。

## 8. Mac 入网实录（T2 前半，2026-10-09 已验证走通）

```sh
# ① 信任 CA（写「管理员域」——网络扩展只认系统级信任，见 §9 排障 ②）
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ./tls/ca.crt
# 验证条目已写入管理员域（必须看到 kSecTrustSettingsResultTrustRoot）：
security dump-trust-settings -d | grep -A3 dsh

# ② 入网（App Store 版无自定义 login server 入口，走 App 内置 CLI）
sudo /Applications/Tailscale.app/Contents/MacOS/Tailscale up \
  --login-server=https://$VPS_IP:8443 \
  --accept-dns=false \
  --authkey=<key①> \
  --timeout=30s

# ③ 验证
/Applications/Tailscale.app/Contents/MacOS/Tailscale status   # → 100.64.0.x superjie-mac
# VPS 上：sudo headscale nodes list  → mac 节点 online（V2 前半 ✅）
```

## 9. 排障实录（2026-10-09 实测踩过的三个坑，T5 iPhone 必读）

**① 叶子证书有效期 > 825 天 → Apple 拒收。**
症状：curl / openssl 全绿，但 Tailscale 扩展报 `x509: "headscale" certificate is not standards compliant` + `Trust evaluate failure: [leaf OtherTrustValidityPeriod]`。
原因：Apple Security 框架要求 TLS 服务器叶子证书 ≤ 825 天；curl/openssl 不校验此项，**不能拿 curl 当判据**。`gen-certs.sh` 叶子已固定 825 天，CA 不受此限（10 年）。

**② 信任条目落错域 → 网络扩展不认。**
症状：扩展报 `x509: certificate signed by unknown authority` + `Trust evaluate failure: [root AnchorTrusted]`，但同一台机器上 `curl`（用户身份）正常。
原因：macOS 信任分域——**用户域（login 钥匙串）curl 能看到；网络扩展以系统上下文运行，只认管理员域**。`security add-trusted-cert -d` 依赖系统弹窗确认，弹窗被吞时命令静默无效。可靠做法 = 钥匙串访问 GUI：左侧选「**系统**」钥匙串（不是「登录」），双击 CA → 信任 → 始终信任。写完必须用 `security dump-trust-settings -d` 复查条目真的在管理员域。

**③ 证书 / key 不配对 → 服务启动即崩。**
症状：VPS `headscale` 无限重启，日志 `tls: private key does not match public key`。
原因：多轮重签后 server.crt 与 server.key 来自不同批次。`gen-certs.sh` 已内置配对自检（公钥指纹比对，不一致即退出）；成对产物重传时必须三件套一起传。

## 10. 后续步骤（别期执行，此处只留索引）

- T2：Mac 装官方 Tailscale 客户端 → login server 指向 `https://$VPS_IP:8443` + key① 入网 → `headscale nodes list` 见 mac online（判据 V2 前半）→ 网关监听改绑 tailnet IP。
- T5：iPhone App 设置页输 key② 入网 → `headscale nodes list` 见 iphone online（V2 后半）。
- 运维：升级 = 换 deb 重装（配置与 sqlite 不动）；备份 = 定期拷 `/var/lib/headscale/db.sqlite`。

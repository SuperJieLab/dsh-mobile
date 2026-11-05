#!/usr/bin/env bash
#
# dsh-mobile — 装好网关插件，并告诉你下一步做什么。
#
# 真正的安装逻辑在 `gateway/install.sh`：那份自洽（进那个目录就能装自己）。
# 本脚本只做编排 —— 调它，然后打印「怎么启动、怎么配对」。**不复制它的逻辑**：
# 两份逻辑就是两份事实，改一处漏一处不会报错。
#
# 用法：
#   ./install.sh                 装本仓库里的网关（开发用，profile 指向工作区）
#   ./install.sh --from-release  装 GitHub Release 上的发布包（装完是副本，不依赖工作区）
#   ./install.sh --start         安装后直接启动 dsh
#   ./install.sh --revoke        撤销全部已配对设备（清空凭证文件）
#                                撤销后手机的下一次请求即 401，重新走配对流程即恢复
#
# 环境变量：
#   DSH_PROFILE   装进哪个 profile（默认 web）
#   DSH_HOME      dsh 的 home 目录（默认 ~/.dsh）
#   DSH_CMD       用哪个 dsh（默认 `npx --yes @deepseek-ai/dsh@alpha`）
#   DSH_GATEWAY_RELEASE_URL  发布包地址（默认本仓库 latest release 的固定附件名）
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE="$REPO/gateway"
PROFILE="${DSH_PROFILE:-web}"
DSH_CMD="${DSH_CMD:-npx --yes @deepseek-ai/dsh@alpha}"

RELEASE_URL="${DSH_GATEWAY_RELEASE_URL:-https://github.com/SuperJieLab/dsh-mobile/releases/latest/download/dsh-mobile-gateway.tgz}"

say() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

[ -x "$PACKAGE/install.sh" ] || die "找不到 $PACKAGE/install.sh —— 这是仓库根吗？"

FROM_RELEASE=0
case "${1:-}" in
  # 撤销是网关自己的事（清的是它的凭证文件），转过去就完了。
  --revoke) exec "$PACKAGE/install.sh" --revoke ;;
  --from-release) FROM_RELEASE=1 ;;
  --start) ;;
  "") ;;
  *) die "不认识的参数：$1（只有 --start、--from-release 与 --revoke）" ;;
esac

# 两条安装路径只差「装哪个东西」，装配、迁移与自检都在网关自己那份脚本里。
# 远程模式装的是一个 .tgz，因此装完是**副本**：工作区被移动或删掉都不影响 profile。
if [ "$FROM_RELEASE" = 1 ]; then
  command -v curl >/dev/null 2>&1 || die "需要 curl 下载发布包"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  TGZ="$WORK/dsh-mobile-gateway.tgz"
  say "→ 下载发布包：$RELEASE_URL"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 -o "$TGZ" "$RELEASE_URL" \
    || die "下载失败 —— 网络不通，或这个 release 还没挂附件：$RELEASE_URL"
  say "   已下载 $(du -h "$TGZ" | cut -f1)"
  DSH_GATEWAY_SPEC="$TGZ" "$PACKAGE/install.sh"
else
  "$PACKAGE/install.sh"
fi

# ── 下一步该做什么 ──────────────────────────────────────────────────────────
say ""
say "启动："
say "    npx @deepseek-ai/dsh@alpha $PROFILE"
say ""
say "看到 [dsh-mobile-gateway] listening 之后，用手机 App 连："
say "    设置 → 组网 → 网关地址填 http://<这台机器的 tailnet 地址>:3081"
say "    （tailscale ip -4 能看到；不是局域网 IP —— App 走 Tailscale，不走同一 Wi-Fi）"
say ""
say "首次使用：启动日志里有 6 位配对码（10 分钟有效），在手机 App 里输入完成配对。"
say "撤销已配对设备：./install.sh --revoke"

if [ "${1:-}" = "--start" ]; then
  say ""
  say "→ 启动 dsh"
  # shellcheck disable=SC2086
  exec $DSH_CMD "$PROFILE"
fi

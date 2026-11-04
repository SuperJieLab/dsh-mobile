#!/usr/bin/env bash
#
# dsh-mobile — 装好网关插件，并告诉你下一步做什么。
#
# 真正的安装逻辑在 `gateway/install.sh`：那份自洽（进那个目录就能装自己）。
# 本脚本只做编排 —— 调它，然后打印「怎么启动、怎么配对」。**不复制它的逻辑**：
# 两份逻辑就是两份事实，改一处漏一处不会报错。
#
# 用法：
#   ./install.sh            只安装
#   ./install.sh --start    安装后直接启动 dsh
#   ./install.sh --revoke   撤销全部已配对设备（清空凭证文件）
#                           撤销后手机的下一次请求即 401，重新走配对流程即恢复
#
# 环境变量：
#   DSH_PROFILE   装进哪个 profile（默认 web）
#   DSH_HOME      dsh 的 home 目录（默认 ~/.dsh）
#   DSH_CMD       用哪个 dsh（默认 `npx --yes @deepseek-ai/dsh@alpha`）
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE="$REPO/gateway"
PROFILE="${DSH_PROFILE:-web}"
DSH_CMD="${DSH_CMD:-npx --yes @deepseek-ai/dsh@alpha}"

say() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

[ -x "$PACKAGE/install.sh" ] || die "找不到 $PACKAGE/install.sh —— 这是仓库根吗？"

case "${1:-}" in
  # 撤销是网关自己的事（清的是它的凭证文件），转过去就完了。
  --revoke) exec "$PACKAGE/install.sh" --revoke ;;
  --start) "$PACKAGE/install.sh" ;;
  "") "$PACKAGE/install.sh" ;;
  *) die "不认识的参数：$1（只有 --start 与 --revoke）" ;;
esac

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

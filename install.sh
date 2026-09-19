#!/usr/bin/env bash
#
# dsh-mobile — 把 Mac 侧的 mac-gateway 插件装进一个 dsh profile。
#
# 为什么需要脚本：装插件要在 profile 的 package.json 里记一条「插件在哪」的
# 绝对路径。手抄那串路径就是「同一个事实写两处」，抄错还不会报错。脚本自己
# 算出仓库位置，所以这一步不再依赖人记住任何路径。
#
# 用法：
#   ./install.sh            只安装
#   ./install.sh --start    安装后直接启动 dsh
#
# 环境变量：
#   DSH_PROFILE   装进哪个 profile（默认 web）
#   DSH_HOME      dsh 的 home 目录（默认 ~/.dsh）
#   DSH_CMD       用哪个 dsh（默认 `npx --yes @deepseek-ai/dsh@alpha`）
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE="$REPO/mac-gateway"
PROFILE="${DSH_PROFILE:-web}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_CMD="${DSH_CMD:-npx --yes @deepseek-ai/dsh@alpha}"

say() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

# ── 前置检查 ────────────────────────────────────────────────────────────────
# dsh plugin 只是 pnpm 的一层壳：它把参数原样转发给 pnpm 执行，
# 所以 pnpm 必须在 PATH 上，dsh 自己不带安装器。
command -v pnpm >/dev/null 2>&1 || die "需要 pnpm —— 装一个：brew install pnpm"
command -v node >/dev/null 2>&1 || die "需要 node（^22.19.0 或 >=24.0.0）"

# `add` 要的是「包」，不是「仓库」：包的定义是有 package.json 的那一层。
[ -f "$PACKAGE/package.json" ] || die "找不到 $PACKAGE/package.json —— 这是仓库的 mac-gateway 目录吗？"

# ── 挡住一个会静默出错的坑 ──────────────────────────────────────────────────
# 包里自带的 cordis.patch.yml 与手写进 profile patch 的那段 insert 用的是
# 同一个 id。两处都在，这一行就会进树两次。
# （本脚本装完之后，profile patch 里不应该再有它。）
PATCH="$DSH_HOME/profiles/$PROFILE/cordis.patch.yml"
if [ -f "$PATCH" ] && grep -q 'id: mac-gateway' "$PATCH"; then
  die "$PATCH 里还有一段手抄的 mac-gateway insert。
    它与本包自带的 patch 层 id 相同 —— 那一行会进树两次。
    删掉那一段后重跑本脚本（文件顶部有说明它本来该长什么样）。"
fi

# ── 安装 ────────────────────────────────────────────────────────────────────
# 用绝对路径：dsh 会把相对路径先按**调用时的当前目录**锚定，
# 而这里要装的确定是 $PACKAGE，不该随调用者所在目录变化。
say "→ 把 $PACKAGE 装进 profile「$PROFILE」"
# shellcheck disable=SC2086
$DSH_CMD plugin --profile "$PROFILE" add "$PACKAGE"

# ── 自检（无副作用：--dump-config 组合树但不调用插件的 apply）────────────────
# shellcheck disable=SC2086
TREE="$($DSH_CMD --profile "$PROFILE" --dump-config 2>/dev/null)"
case "$TREE" in
  *"id: mac-gateway"*) say "✅ mac-gateway 已进入组合树" ;;
  *) die "组合树里没有 mac-gateway 行 —— 看上面 pnpm 的输出。" ;;
esac

# ── 下一步该做什么 ──────────────────────────────────────────────────────────
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
[ -n "$LAN_IP" ] || LAN_IP="<你的局域网 IP>"

say ""
say "启动："
say "    npx @deepseek-ai/dsh@alpha $PROFILE"
say ""
say "看到 [mac-gateway] listening on http://0.0.0.0:3081 之后，"
say "手机连同一个 Wi-Fi 打开："
say "    http://$LAN_IP:3081"
say ""
say "⚠️ 那个端口目前没有任何鉴权（鉴权在 M4）—— 同 Wi-Fi 下人人可达，别在公共网络上开着。"

if [ "${1:-}" = "--start" ]; then
  say ""
  say "→ 启动 dsh"
  exec $DSH_CMD "$PROFILE"
fi

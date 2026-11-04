#!/usr/bin/env bash
#
# dsh-mobile-gateway — 把本插件装进一个 dsh profile。
#
# 为什么需要脚本：装插件要在 profile 的 package.json 里记一条「插件在哪」的
# 绝对路径。手抄那串路径就是「同一个事实写两处」，抄错还不会报错。脚本自己
# 算出包的位置，所以这一步不再依赖人记住任何路径。
#
# 仓库根的 `../install.sh` 调的就是本脚本 —— 那个是完整入口（装完还告诉你
# 下一步怎么启动、怎么配对）。直接跑本脚本只做「装 + 自检」。
#
# 用法：
#   ./gateway/install.sh            只安装
#   ./gateway/install.sh --revoke   撤销全部已配对设备（清空凭证文件）
#                                       撤销后手机的下一次请求即 401，重新配对即恢复
#
# 环境变量：
#   DSH_PROFILE   装进哪个 profile（默认 web）
#   DSH_HOME      dsh 的 home 目录（默认 ~/.dsh）
#   DSH_CMD       用哪个 dsh（默认 `npx --yes @deepseek-ai/dsh@alpha`）
#
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${DSH_PROFILE:-web}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_CMD="${DSH_CMD:-npx --yes @deepseek-ai/dsh@alpha}"

say() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

# ── 前置检查 ────────────────────────────────────────────────────────────────
# dsh plugin 只是 pnpm 的一层壳：它把参数原样转发给 pnpm 执行，
# 所以 pnpm 必须在 PATH 上，dsh 自己不带安装器。
command -v pnpm >/dev/null 2>&1 || die "需要 pnpm —— 装一个：brew install pnpm"
command -v node >/dev/null 2>&1 || die "需要 node —— 版本要求见 package.json 的 engines"

# 版本下限从 package.json 的 `engines.node` 读出来显示，规则写在这一处 ——
# 两处各写一份的话，改了一处、报错信息就会指着一个已经不成立的版本。
node -e '
const fs = require("fs");
const { engines } = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const [major, minor] = process.versions.node.split(".").map(Number);
const ok = (major === 22 && minor >= 19) || major >= 24;
if (!ok) {
  console.error(`❌ node ${process.versions.node} 太旧 —— 需要 ${engines?.node ?? "(未声明)"}`);
  process.exit(1);
}
' "$PACKAGE/package.json" || exit 1

# ── --revoke：撤销全部已配对设备 ────────────────────────────────────────────
# 凭证文件与插件读的是同一路径；清空成 {version:1} 而不是删文件 ——
# 撤销是回到「未配对」，不是弄坏插件。
if [ "${1:-}" = "--revoke" ]; then
  CRED_FILE="$DSH_HOME/dsh-mobile/credentials.json"
  if [ -f "$CRED_FILE" ]; then
    printf '{\n  "version": 1\n}\n' > "$CRED_FILE"
    say "✅ 已撤销全部已配对设备（$CRED_FILE 已清空）。"
    say "   手机的下一次请求会收到 401；重新配对即可恢复。"
  else
    say "没有凭证文件（${CRED_FILE}）—— 本来就没有已配对的设备。"
  fi
  exit 0
fi

# ── 迁移旧 id 的配置段 ──────────────────────────────────────────────────────
# profile 里的 `- id: mac-gateway` + `config:` 是「给已有行传配置」。插件 id 改成
# `dsh-mobile-gateway` 之后，那一段就指向一个不存在的行 —— 而报错不会说「你配的 id 过期了」。
#
# 只替换**完全匹配**的那一行：`config:` 的内容原样留着。用 node 而不是 sed，
# 因为 `sed -i` 的后缀在 GNU 与 BSD 上不同。
PATCH="$DSH_HOME/profiles/$PROFILE/cordis.patch.yml"
if [ -f "$PATCH" ] && grep -q '^- id: mac-gateway$' "$PATCH" 2>/dev/null; then
  say "→ 迁移 profile 配置：id: mac-gateway → id: dsh-mobile-gateway"
  node -e '
const fs = require("fs");
const [path] = process.argv.slice(1);
const before = fs.readFileSync(path, "utf8");
const after = before.replace(/^- id: mac-gateway$/gm, "- id: dsh-mobile-gateway");
if (after !== before) fs.writeFileSync(path, after);
' "$PATCH"
fi

# ── 安装 ────────────────────────────────────────────────────────────────────
# 用绝对路径：dsh 会把相对路径先按**调用时的当前目录**锚定，
# 而这里要装的确定是 $PACKAGE，不该随调用者所在目录变化。
say "→ 把 $PACKAGE 装进 profile「${PROFILE}」"
# shellcheck disable=SC2086
$DSH_CMD plugin --profile "$PROFILE" add "$PACKAGE"

# ── 自检：数组合树里有几行 dsh-mobile-gateway ──────────────────────────────────────
# **不数行的话，「进了树两次」是看不出来的** —— 症状是端口被占两次、事件被处理两遍，
# 而报错不会说「你装了两遍」。`--dump-config` 无副作用（组合树但不调用插件的 apply），
# 所以这一步可以放心跑。
#
# 为什么不用「装之前 grep patch 文件」：profile 里合法的写法是 `- id: dsh-mobile-gateway`
# 后面跟 `config:`（配置覆盖，没有 `insert:` 包装），而重复项是 `- insert:` 下面
# 包着 `- id: dsh-mobile-gateway`。只看 `id: dsh-mobile-gateway` 这个字符串会把**正常配置**当成
# 重复项，于是「想给网关传 host」的人连装都装不上。数组合树是看事实，不是猜意图。
# shellcheck disable=SC2086
TREE="$($DSH_CMD --profile "$PROFILE" --dump-config 2>/dev/null)"
COUNT=$(printf '%s\n' "$TREE" | grep -c 'id: dsh-mobile-gateway' || true)
COUNT=${COUNT:-0}

case "$COUNT" in
  0)
    die "组合树里没有 dsh-mobile-gateway 行 —— 看上面 pnpm 的输出。"
    ;;
  1)
    say "✅ dsh-mobile-gateway 已进入组合树"
    ;;
  *)
    die "组合树里有 $COUNT 行 dsh-mobile-gateway —— 插件进了树两次，端口与事件都会被处理两遍。

    查 $DSH_HOME/profiles/$PROFILE/cordis.patch.yml：
      · 有一段 \`- insert:\` 包着 \`- id: dsh-mobile-gateway\` → 那是重复项，删掉它；
      · \`- id: dsh-mobile-gateway\` 后面直接跟 \`config:\` → 那是配置覆盖，**要留着**。"
    ;;
esac

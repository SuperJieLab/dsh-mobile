#!/usr/bin/env bash
#
# 打一个可复现的 Release：版本号来自 git tag，dSYM 必须跟包一起留下。
#
# 用法：
#   ./scripts/release.sh              归档，校验 dSYM，不导出 ipa
#   ./scripts/release.sh --ipa        再加一步导出 ipa（要签名配置齐全）
#
# 为什么版本号必须来自 tag，而不是从 pbxproj 读：
#   归档的产物回答一个问题 —— **这个包是哪份代码**。pbxproj 里的数字是人手改的，
#   它与 commit 之间没有任何约束；而 tag 指向一个具体的 commit。所以「没有 tag 就
#   拒绝归档」不是严格，是这件事的定义。
#
# 为什么 dSYM 要校验 UUID：
#   Release 的符号不在二进制里（`dwarf-with-dsym`），它在独立的 dSYM 文件里。而
#   **UUID 不匹配的 dSYM 一样能打开、一样有内容**，只是解出来的行号是错的 —— 那比
#   没有 dSYM 更坏，因为你会相信它。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

OUT="$ROOT/build"
ARCHIVE="$OUT/DshMobile.xcarchive"
EXPORT_IPA=0
[[ "${1:-}" == "--ipa" ]] && EXPORT_IPA=1

say() { printf '%s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

# ── 前提：工作区必须干净 ────────────────────────────────────────────────────
# 带未提交改动归档，得到的包对不上任何 commit —— 而「对得上」正是这次归档的意义。
# 空目录（未跟踪）不算：`--porcelain` 里 `??` 开头的行不影响产物。
DIRTY=$(git status --porcelain --untracked-files=no)
if [[ -n "$DIRTY" ]]; then
  say "工作区有未提交的改动："
  printf '%s\n' "$DIRTY"
  die "先提交（或 stash）再归档 —— 否则这个包对不上任何 commit"
fi

# ── 版本号：tag 是唯一真源 ──────────────────────────────────────────────────
TAG=$(git describe --tags --exact-match HEAD 2>/dev/null) || {
  die "HEAD 上没有 tag。发布必须打一个：
     git tag -a v0.1.0 -m \"$(git log -1 --format=%s)\"
     然后重跑本脚本"
}

# 只接受 x.y.z（可带 v 前缀）：App Store 的 CFBundleShortVersionString 就是这个形状，
# 带后缀（-beta、-5-gabc）会被拒，也会让「按版本比较」变成字符串比较。
VERSION="${TAG#v}"
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  die "tag「${TAG}」不是 x.y.z 形状（可带 v 前缀）。CFBundleShortVersionString 不接受后缀"
fi

# CFBundleVersion 必须单调递增且唯一。用提交数：只增不减，且与代码一一对应。
BUILD=$(git rev-list --count HEAD)
COMMIT=$(git rev-parse --short HEAD)

say "版本 ${VERSION}（build ${BUILD}）· commit ${COMMIT} · tag ${TAG}"

# ── 归档 ────────────────────────────────────────────────────────────────────
mkdir -p "$OUT"
rm -rf "$ARCHIVE"

# 本机沙箱（WorkBuddy 的 Bash）要关掉 Swift 宏插件沙箱；CI / 用户终端不需要。
EXTRA=()
if [[ -z "${CI:-}" ]]; then
  EXTRA=(OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox')
fi

say "归档中…"
xcodebuild archive \
  -project ios/DshMobile.xcodeproj \
  -scheme DshMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  ${EXTRA[@]+"${EXTRA[@]}"} > "$OUT/archive.log" 2>&1

if [[ ! -d "$ARCHIVE" ]]; then
  say "归档失败，错误："
  grep -E 'error:|The following build commands failed' "$OUT/archive.log" | head -20
  die "完整日志：${OUT#"$ROOT"/}/archive.log"
fi

# ── dSYM：必须存在，且 UUID 与二进制一致 ────────────────────────────────────
DSYM="$ARCHIVE/dSYMs/DshMobile.app.dSYM"
APP="$ARCHIVE/Products/Applications/DshMobile.app"
BIN="$APP/DshMobile"

[[ -d "$DSYM" ]] || die "归档里没有 dSYM —— Release 的符号就永远丢了，这个包不能发"
[[ -f "$BIN" ]] || die "归档里没有可执行文件（路径变了？）：$BIN"

BIN_UUID=$(dwarfdump --uuid "$BIN" 2>/dev/null | sed -E 's/.*UUID: ([0-9A-F-]+).*/\1/' | head -1)
DSYM_UUID=$(dwarfdump --uuid "$DSYM" 2>/dev/null | sed -E 's/.*UUID: ([0-9A-F-]+).*/\1/' | head -1)

if [[ -z "$BIN_UUID" || "$BIN_UUID" != "$DSYM_UUID" ]]; then
  say "二进制 UUID：${BIN_UUID:-<取不到>}"
  say "dSYM   UUID：${DSYM_UUID:-<取不到>}"
  die "UUID 不一致 —— 这份 dSYM 解不出正确的行号（比没有更坏，因为你会相信它）"
fi

# 体积与符号数：一个只有几千字节的 dSYM 通常意味着符号被剥掉了。
# `du -sh` 而不是 `du -h`：后者对目录会逐层列出，结论行里会塞进十几行数字。
DSYM_SIZE=$(du -sh "$DSYM" | cut -f1)

# ── 可选：导出 ipa ──────────────────────────────────────────────────────────
IPA_NOTE="未导出（--ipa 才会导出）"
if [[ $EXPORT_IPA -eq 1 ]]; then
  PLIST="$OUT/exportOptions.plist"
  # method=development：免费 Apple ID / 开发证书那条路。Ad Hoc 与 App Store 都要付费账号。
  cat > "$PLIST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>development</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
</dict>
</plist>
PLIST_EOF

  say "导出 ipa…"
  if xcodebuild -exportArchive -archivePath "$ARCHIVE" \
       -exportOptionsPlist "$PLIST" -exportPath "$OUT/ipa" \
       -allowProvisioningUpdates > "$OUT/export.log" 2>&1; then
    IPA_NOTE="$(ls "$OUT/ipa"/*.ipa 2>/dev/null | head -1)"
    [[ -n "$IPA_NOTE" ]] || IPA_NOTE="导出成功但没找到 .ipa（见 ${OUT#"$ROOT"/}/export.log）"
  else
    # 导出失败不算整体失败：归档与 dSYM 已经到手，那才是这次要的东西。
    say "⚠️ ipa 导出失败（归档与 dSYM 仍然有效）："
    grep -E 'error:' "$OUT/export.log" | head -5
    IPA_NOTE="导出失败（见 ${OUT#"$ROOT"/}/export.log）"
  fi
fi

# ── 网关的版本跟着 tag 走 ────────────────────────────────────────────────────
# `mac-gateway/package.json` 的 version 一直停在 0.0.1，也不参与任何判断 —— 排查时问
# 「你那个网关是哪一版」答不出来。跟着 tag 走，「一个 tag = 一套版本」，对得起来。
#
# 放在归档**之后**：写它会让工作区变脏，而「工作区干净才归档」正是前面那条前置检查的
# 意义所在。先出包、再改文件，两件事不互相破坏。
GATEWAY_MANIFEST="${ROOT}/mac-gateway/package.json"
if [[ -f "$GATEWAY_MANIFEST" ]]; then
  GATEWAY_NOTE="$(node -e '
const fs = require("fs");
const [path, version] = process.argv.slice(1);
const data = JSON.parse(fs.readFileSync(path, "utf8"));
if (data.version === version) { console.log("已是 " + version); process.exit(0); }
data.version = version;
fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
console.log("已写成 " + version + "（记得提交）");
' "$GATEWAY_MANIFEST" "$VERSION")"
else
  GATEWAY_NOTE="（没有 mac-gateway/package.json，跳过）"
fi

# ── 结论 ────────────────────────────────────────────────────────────────────
say ""
say "────────────────────────────────────────────"
say "版本        ${VERSION} (${BUILD})"
say "commit      ${COMMIT}"
say "归档        ${ARCHIVE#"$ROOT"/}"
say "dSYM        ${DSYM#"$ROOT"/}  (${DSYM_SIZE})"
say "UUID        ${BIN_UUID}"
say "ipa         ${IPA_NOTE}"
say "网关        ${GATEWAY_NOTE}"
say "────────────────────────────────────────────"
say ""
say "符号化一条崩溃栈："
say "  atos -o \"${DSYM#"$ROOT"/}/Contents/Resources/DWARF/DshMobile\" -arch arm64 -l <load address> <address>"
say ""
say "把 dSYM 与 ipa 一起归档（或上传到崩溃服务）—— 丢了 dSYM，这个包的崩溃栈就永远解不出。"

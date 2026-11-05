#!/usr/bin/env bash
#
# 两端的统一闸门。本地与 CI 调的是**同一条命令** —— 两份命令就是两份事实，
# 而「本地绿了 CI 红」最难查的正是它们哪里不一样。
#
# 用法：
#   ./scripts/ci.sh              四节都跑
#   ./scripts/ci.sh gateway      只跑网关（秒级，改网关时用）
#   ./scripts/ci.sh lint         只跑注释与引用的纪律（秒级，改注释时用）
#   ./scripts/ci.sh judges       只跑源码级判据（macOS 上跑，十几秒）
#   ./scripts/ci.sh ios          只跑 iOS 行为测试（分钟级）
#
# 环境变量：
#   DSH_SIM_UDID     指定模拟器。不设时：先找已启动的 iPhone，再找第一台可用的。
#   DSH_MIN_GATEWAY  网关判据条数下限。低于它视为「扫描面缩水」，红。
#   DSH_MIN_LINT     lint 扫描的文件数下限。同一用意：少扫了就是没守。
#   DSH_MIN_IOS      iOS 判据条数下限。同上。
#   CI               由 CI 自己设。设了就不加本机沙箱补丁（见下）。
#
# 为什么结论要自己解析而不只看退出码：
#   `xcodebuild test` 在本机会「打印完不退出」（项目记忆里那个坑），而 CI 上
#   反过来 —— 它退出了，但失败可能只写在日志里。两处都不该用退出码当唯一依据。
#   所以这里以「日志里的条数与失败数」为准，退出码只作辅助。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 不带前导点：`actions/upload-artifact@v4` 默认排除隐藏文件（include-hidden-files
# 默认 false），叫 .ci-out 会让日志在 CI 上「上传成功但没有文件」。
OUT="${ROOT}/ci-out"
mkdir -p "$OUT"

FAILED=0

say() { printf '%s\n' "$*"; }
hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

# 构建摘要（CI 上指向 $GITHUB_STEP_SUMMARY，本地不设就什么都不做）。
# 为什么要有它：判据条数掉下去时，测试照样全绿 —— 少扫一个目录没人会发现。
# 条数摆在每一轮的摘要里，「少了」才会变成一个看得见的事实。
# CI 上 `$GITHUB_STEP_SUMMARY` 由 runner 自己给，所以 workflow 里不必传参；
# `DSH_SUMMARY` 留给本地指到任意文件（想留档时用）。
SUMMARY="${DSH_SUMMARY:-${GITHUB_STEP_SUMMARY:-}}"
summary() {
  [[ -n "$SUMMARY" ]] || return 0
  printf '%s\n' "$*" >> "$SUMMARY"
}
summary_head() {
  [[ -n "$SUMMARY" ]] || return 0
  # 摘要文件在 CI 上由 runner 预先创建（可能已有别的内容），所以判据是
  # 「表头在不在」，不是「文件在不在」。
  grep -q '^| 侧 | 判据 |' "$SUMMARY" 2>/dev/null \
    || printf '| 侧 | 判据 | 失败 | 下限 | 结论 |\n|---|---|---|---|---|\n' >> "$SUMMARY"
}

# ── 网关 ────────────────────────────────────────────────────────────────────
# `npm test` 自己先跑 `tsc --noEmit`（package.json 的 scripts.test），所以
# 类型闸门不需要在这里再来一次 —— 重跑一遍只会让「哪一道拦住的」变模糊。
run_gateway() {
  hr; say "网关 · npm test"; hr
  local log="$OUT/gateway.log"

  ( cd "$ROOT/gateway" && npm test ) >"$log" 2>&1
  local status=$?

  # `# tests N` / `# fail N` 是 node:test 的 TAP 尾巴。
  # 用 `[0-9][0-9]*` 而不是 `[0-9]\+`：BSD 与 toybox 的 sed 都不认 `\+`
  # （GNU 扩展），而它失败的方式是**静默回空**，看起来像「测试没跑起来」。
  local total fail
  total=$(sed -n 's/^# tests \([0-9][0-9]*\)$/\1/p' "$log" | tail -1)
  fail=$(sed -n 's/^# fail \([0-9][0-9]*\)$/\1/p' "$log" | tail -1)

  if [[ -z "$total" ]]; then
    # 解析不出条数 = 这一轮根本没跑起来（编译失败、依赖缺失）。这跟「跑了但红」
    # 是两件事，不能都报成「测试失败」—— 否则查的人会去翻判据。
    say "❌ 网关：没跑出结果（日志尾部见下）"
    tail -20 "$log"
    FAILED=1
    return
  fi

  # 变量紧邻中文时必须用 ${}：macOS 自带的 bash 3.2 会把全角字符的首字节
  # 当成变量名的一部分（`$status）` → 变量名 `status\xef`），报 unbound variable。
  # bash 5 不会 —— 这正是「本地绿、CI 红」最容易出现的地方。
  say "网关：${total} 条，失败 ${fail:-?}（退出码 ${status}）"
  summary_row 网关 "$total" "${fail:-1}" "${DSH_MIN_GATEWAY:-0}"
  if [[ "${fail:-1}" != "0" ]]; then
    say "❌ 失败的判据："
    grep -E '^not ok ' "$log" | head -30
    FAILED=1
  fi
  check_floor gateway "$total" "${DSH_MIN_GATEWAY:-0}"
}

# ── lint ────────────────────────────────────────────────────────────────────
# 注释与引用的纪律住在 `ios/.swiftlint.yml`：那些规则要的是保存即报，所以不进测试。
# 这一节只回答两件事：有没有违规；扫描面有没有缩水 —— 少扫了一批文件，规则看起来还是绿。
#
# 为什么下限盯的是**文件数**而不是「判据条数」：规则条数写在 yml 里，不随扫描面变；
# 会悄悄变小的是被扫到的文件数，那正是「路径推算瞎了」的症状。
run_lint() {
  hr; say "lint · swiftlint"; hr
  local log="$OUT/lint.log"

  if ! command -v swiftlint >/dev/null 2>&1; then
    say "❌ lint：没装 swiftlint —— 这一节不能算通过（装法：brew install swiftlint）"
    FAILED=1
    return
  fi

  # 先验规则自己还活着：规则退化时违规数恒为 0，后面那个「0 违规」就什么都证明不了。
  # 它必须在这条闸门里跑，否则只是一个人会手动执行的脚本。
  if ! "$ROOT/ios/scripts/lint-selftest.sh"; then
    say "❌ lint：规则自测未通过（失配项见上）"
    FAILED=1
    return
  fi

  ( cd "$ROOT/ios" && swiftlint lint --strict ) >"$log" 2>&1
  local status=$?

  # 尾巴形如 `Found 0 violations, 0 serious in 185 files.`
  local violations files
  # `1 violation` 与 `2 violations` 是两种单复数写法，用 `-E` 的 `?` 一次收掉；
  # 只认复数会让「正好一条违规」落进「没跑出结果」那一支，两种红的处置完全不同。
  violations=$(sed -nE 's/.*Found ([0-9]+) violations?.*/\1/p' "$log" | tail -1)
  files=$(sed -nE 's/.* in ([0-9]+) files\.$/\1/p' "$log" | tail -1)

  if [[ -z "${violations:-}" ]]; then
    say "❌ lint：没跑出结果（退出码 ${status}，日志尾部见下）"
    tail -20 "$log"
    FAILED=1
    return
  fi

  if [[ "$violations" != "0" ]]; then
    say "❌ lint：${violations} 条违规（退出码 ${status}）"
    grep -E ': (error|warning): ' "$log" | head -20
    FAILED=1
  else
    say "lint：0 条违规，扫描 ${files:-?} 个文件"
  fi

  summary_row lint "${files:-0}" "$violations" "${DSH_MIN_LINT:-0}"
  check_floor lint "${files:-0}" "${DSH_MIN_LINT:-0}"
}

# ── 判据 ────────────────────────────────────────────────────────────────────
# 这批判据读的是仓库里的源码与样本，不碰 App 运行时 —— 所以它们跑在 macOS 上：
# 手机上根本读不到宿主路径。它们与「行为测试」分成两个 target，就是为了这条区别。
#
# 为什么结论要自己判、不看退出码：`xcodebuild test` 在本机打印完不一定退出（项目记忆里的坑），
# 而 CI 上它退出了、失败却可能只写在日志里。两个方向都不可靠，只认日志里的结论行。
run_judges() {
  hr; say "判据 · xcodebuild test（macOS）"; hr
  local log="$OUT/judges.log"

  local -a extra=()
  if [[ -z "${CI:-}" ]]; then
    extra=(OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox')
  fi

  xcodebuild test \
    -project "$ROOT/ios/DshMobile.xcodeproj" \
    -scheme DshMobileJudges \
    -destination 'platform=macOS' \
    "${extra[@]}" >"$log" 2>&1

  if grep -q '\*\* TEST FAILED \*\*' "$log"; then
    say "❌ 判据：有失败"
    grep -E ': error: ' "$log" | head -20
    FAILED=1
    return
  fi
  if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
    # 没跑出结论与「跑了且过」是两件事，不能都报成失败原因不明。
    say "❌ 判据：没跑出结论（日志尾部见下）"
    tail -20 "$log"
    FAILED=1
    return
  fi
  say "判据：跑完，全部通过"
}

# ── 判据条数下限 ────────────────────────────────────────────────────────────
# 守的是「扫描面静默缩水」：少扫一个目录，判据照样全绿，而你看不出来。
# 下限只能往上调 —— 调低它等于承认「这次少了几条没关系」。
check_floor() {
  local side="$1" total="$2" floor="$3"
  if [[ "$floor" == "0" ]]; then
    say "   （未设条数下限；CI 会设，见 workflow）"
    return
  fi
  if (( total < floor )); then
    say "❌ ${side} 判据条数 ${total} 低于下限 ${floor} —— 扫描面缩水了"
    FAILED=1
  else
    say "   ${side} 条数 ${total} ≥ 下限 ${floor}"
  fi
}

# 摘要里的一行。`verdict` 与退出码同源，不另算一遍 —— 两处各判一次，
# 总有一处会先漂。
summary_row() {
  local side="$1" total="$2" fail="$3" floor="$4"
  local verdict="✅"
  if [[ "${fail:-1}" != "0" ]] || { [[ "$floor" != "0" ]] && (( total < floor )); }; then
    verdict="❌"
  fi
  summary_head
  summary "| ${side} | ${total} | ${fail:-?} | ${floor} | ${verdict} |"
}

# ── 模拟器 ──────────────────────────────────────────────────────────────────
# 不能写死 UDID：CI 的 runner 上那台设备不存在，而本机的设备号换一台机器就变。
# 选择顺序按「最可能已经就绪」排：显式指定 > 已启动 > 第一台可用。
pick_simulator() {
  if [[ -n "${DSH_SIM_UDID:-}" ]]; then
    printf '%s' "$DSH_SIM_UDID"; return
  fi

  # 不依赖 python3：runner 上它不一定在 PATH 上，而这里要的只是「从一行里抠出 UDID」。
  # `simctl` 的输出按运行时分成 `-- iOS 27.0 --` 这样的节，别的运行时里也有叫 iPhone 的
  # 配对设备，所以要先限定在 iOS 节内再找。
  local udid
  udid=$(xcrun simctl list devices booted 2>/dev/null \
         | awk '/^-- iOS/{f=1; next} /^-- /{f=0} f && /iPhone/{print; exit}' \
         | sed -E 's/.*\(([0-9A-Fa-f-]+)\).*/\1/')
  if [[ -n "$udid" ]]; then printf '%s' "$udid"; return; fi

  udid=$(xcrun simctl list devices available 2>/dev/null \
         | awk '/^-- iOS/{f=1; next} /^-- /{f=0} f && /iPhone/{print; exit}' \
         | sed -E 's/.*\(([0-9A-Fa-f-]+)\).*/\1/')
  printf '%s' "$udid"
}

# ── iOS ─────────────────────────────────────────────────────────────────────
# 两步而不是一步（`xcodebuild test`）：
#   build-for-testing 失败 = 代码编不过；test-without-building 失败 = 判据红。
#   合成一步时这两种都是「测试失败」，而补救完全不同。
run_ios() {
  hr; say "iOS · xcodebuild"; hr

  local udid
  udid=$(pick_simulator)
  if [[ -z "$udid" ]]; then
    say "❌ 找不到可用的 iPhone 模拟器"
    FAILED=1
    return
  fi
  say "模拟器：${udid}"

  # 本机沙箱（WorkBuddy 的 Bash）会拦 Swift 宏插件，要关掉编译器沙箱；
  # CI 的 runner 没有那层嵌套沙箱，加上只会得到一条查不出原因的警告。
  local -a extra=()
  if [[ -z "${CI:-}" ]]; then
    extra=(OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox')
  fi

  local project="$ROOT/ios/DshMobile.xcodeproj"
  local dest="id=$udid"
  local build_log="$OUT/ios-build.log"
  local test_log="$OUT/ios-test.log"

  # 设备必须真的 Booted，否则 xcodebuild 会挂十几分钟零输出（本机踩过的坑，
  # runner 上一样会撞）。`bootstatus -b` 等到 ready 再往下。
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true

  # `"${extra[@]+...}"` 而不是 `"${extra[@]}"`：macOS 自带 bash 3.2 在 `set -u`
  # 下对空数组会报 unbound variable —— 而 CI 那条分支里 extra 恰好是空的。
  xcodebuild build-for-testing \
    -project "$project" -scheme DshMobile -destination "$dest" \
    ${extra[@]+"${extra[@]}"} >"$build_log" 2>&1
  local build_status=$?

  if [[ $build_status -ne 0 ]]; then
    say "❌ 构建失败（这一步没跑任何判据）："
    grep -E 'error:' "$build_log" | head -20
    FAILED=1
    return
  fi

  xcodebuild test-without-building \
    -project "$project" -scheme DshMobile -destination "$dest" >"$test_log" 2>&1
  local test_status=$?

  # 一份日志里每个 suite 各打一行「Executed N tests」，总数取其中最大那一行
  # （最后一行是总计，但并行执行时顺序不保证）。
  local total fail
  total=$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$test_log" \
          | sed -E 's/Executed ([0-9]+) tests?, with ([0-9]+).*/\1/' | sort -n | tail -1)
  fail=$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$test_log" \
         | sed -E 's/.*with ([0-9]+).*/\1/' | sort -n | tail -1)

  if [[ -z "$total" ]]; then
    say "❌ iOS：没跑出结果（日志尾部见下）"
    tail -20 "$test_log"
    FAILED=1
    return
  fi

  say "iOS：${total} 条，失败 ${fail:-?}（退出码 ${test_status}）"
  summary_row iOS "$total" "${fail:-1}" "${DSH_MIN_IOS:-0}"
  if [[ "${fail:-1}" != "0" ]]; then
    say "❌ 失败的判据："
    grep -E 'error: -\[' "$test_log" | head -30
    FAILED=1
  fi
  check_floor ios "$total" "${DSH_MIN_IOS:-0}"
}

# ── 入口 ────────────────────────────────────────────────────────────────────
case "${1:-all}" in
  gateway) run_gateway ;;
  lint)    run_lint ;;
  judges)  run_judges ;;
  ios)     run_ios ;;
  all)     run_gateway; run_lint; run_judges; run_ios ;;
  *) say "用法：$0 [gateway|lint|judges|ios|all]"; exit 2 ;;
esac

hr
if [[ $FAILED -ne 0 ]]; then
  say "结论：有失败。完整日志在 ${OUT#"$ROOT"/}/"
  exit 1
fi
say "结论：全绿。"

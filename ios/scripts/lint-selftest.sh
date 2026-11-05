#!/usr/bin/env bash
#
# 规则自测：证明 `ios/.swiftlint.yml` 里那套正则还认得正例、也没误伤反例。
#
# 规则在 `ios/.swiftlint.yml`，样本在 `ios/scripts/lint-selftest/samples.txt`。
# 由 `scripts/ci.sh` 的 lint 节调用 —— 不进闸门的判据等于没有。
# 退出码：0 = 全部命中符合预期；非 0 = 有规则退化了，或规则与样本对不上。
#
# 为什么要验：零命中型的检查最危险的失效方式是正则被改坏、从此刻起永远不命中 ——
# 那时全仓变绿，而没人事先知道。样本就是这条检查的现场。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 本机的 Bash 在沙箱里，Swift 的宏插件会被嵌套沙箱拦；CI 的 runner 没有那层，
# 加上只会得到一条查不出原因的警告。与 `scripts/ci.sh` 同一口径。
extra=()
if [[ -z "${CI:-}" ]]; then
  extra=(-Xfrontend -disable-sandbox)
fi

cd "$ROOT" || exit 2
exec xcrun swift "${extra[@]}" "$ROOT/ios/scripts/lint-selftest/main.swift"

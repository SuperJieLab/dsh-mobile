#!/bin/sh
#
# 编译并运行占用值的吸收测试（O1–O2）。
#
# UsageState 是纯值类型，不 import SwiftUI / UIKit —— 所以同一手法可用：
# 和 run.sh / run-follow.sh / run-transient.sh 一样编成 macOS 命令行程序跑断言。
#
# 跑法：bash ios/tests/run-usage.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-usage-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/GatewayProtocol.swift" \
  "$here/../Sources/Features/Sessions/UsageState.swift" \
  "$here/TestHarness.swift" \
  "$here/UsageStateTests.swift"

"$out"

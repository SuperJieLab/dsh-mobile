#!/bin/sh
#
# 编译并运行会话详情组装器的测试（A1–A4、A8）。
#
# TranscriptAssembler 是纯状态机，不 import SwiftUI / UIKit —— 所以同一手法可用：
# 和 run.sh / run-follow.sh / run-transient.sh / run-usage.sh 一样编成 macOS
# 命令行程序跑断言。
#
# 跑法：bash ios/tests/run-assembler.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-assembler-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/GatewayProtocol.swift" \
  "$here/../Sources/Features/Sessions/TranscriptAssembler.swift" \
  "$here/TranscriptAssemblerTests.swift"

"$out"

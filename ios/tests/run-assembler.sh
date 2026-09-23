#!/bin/sh
#
# 编译并运行会话详情组装器的测试（A1–A9、切片 S1–S4）。
#
# TranscriptAssembler 是纯状态机，不 import SwiftUI / UIKit —— 所以同一手法可用：
# 和 run.sh / run-follow.sh / run-transient.sh / run-usage.sh 一样编成 macOS
# 命令行程序跑断言。
#
# 切片那一段（窗口会变：打开 / 往回翻 / 冷启动重取）连 `SessionMirror` 一起编 ——
# 那几条判据问的是「同一批事件换一个窗口再看一遍，屏上会变什么」，只有把镜像
# 摆在组装器前面才问得出来。
#
# 跑法：bash ios/tests/run-assembler.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-assembler-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/GatewayProtocol.swift" \
  "$here/../Sources/Core/SessionMirror.swift" \
  "$here/../Sources/Features/Sessions/TranscriptAssembler.swift" \
  "$here/TranscriptAssemblerTests.swift"

"$out"

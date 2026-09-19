#!/bin/sh
#
# 编译并运行 SessionMirror 的接缝测试。
#
# 零依赖：只用 swiftc。状态机刻意不 import SwiftUI / UIKit，所以同一份源码既能
# 被 iOS target 编译，也能在这里被编成 macOS 命令行程序 —— 这正是「接缝」在
# 文件系统上的形态。
#
# 跑法：bash ios/tests/run.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-session-mirror-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Data/GatewayProtocol.swift" \
  "$here/../Sources/Data/SessionMirror.swift" \
  "$here/SessionMirrorTests.swift"

"$out"

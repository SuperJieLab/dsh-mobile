#!/bin/sh
#
# 编译并运行 TailnetNodeState 的状态机断言（M8 O1；跑法与 run.sh 同）。
#
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-mesh-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/MeshNetwork/TailnetNodeState.swift" \
  "$here/TestHarness.swift" \
  "$here/MeshNodeStateTests.swift"

"$out"

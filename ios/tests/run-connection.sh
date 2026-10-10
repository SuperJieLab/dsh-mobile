#!/bin/sh
#
# 编译并运行 ConnectionStore 的连接域断言（R3 N1–N3；跑法与 run-mesh.sh 同）。
#
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-connection-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/MeshNetwork/TailnetNodeState.swift" \
  "$here/../Sources/Core/MeshNetwork/MeshConfig.swift" \
  "$here/../Sources/Core/Connection/ConnectionStore.swift" \
  "$here/TestHarness.swift" \
  "$here/ConnectionStoreTests.swift"

"$out"

#!/bin/sh
#
# 编译并运行 TransientChannel 的契约测试（跑法与 run.sh 同）。
#
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-transient-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/GatewayProtocol.swift" \
  "$here/../Sources/Core/TransientChannel.swift" \
  "$here/TestHarness.swift" \
  "$here/TransientChannelTests.swift"

"$out"

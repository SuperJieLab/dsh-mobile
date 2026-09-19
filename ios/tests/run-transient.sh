#!/bin/sh
#
# 编译并运行 TransientChannel 的接缝测试（跑法与 run.sh 同）。
#
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-transient-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Data/GatewayProtocol.swift" \
  "$here/../Sources/Data/TransientChannel.swift" \
  "$here/TransientChannelTests.swift"

"$out"

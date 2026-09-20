#!/bin/sh
#
# 编译并运行跟随承载下的镜像重放测试（C3）与退避曲线测试（C1 可测部分）。
#
# FollowClient 依赖 URLSession 与定时器，无法编进无网络的 CLI 测试 —— 只把
# 它的可断言行为（退避纯函数）随源码一起编入；完整的重连编排由真机 R3/R4 覆盖。
#
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-follow-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/GatewayProtocol.swift" \
  "$here/../Sources/Core/GatewayClient.swift" \
  "$here/../Sources/Core/CredentialStore.swift" \
  "$here/../Sources/Core/SessionMirror.swift" \
  "$here/../Sources/Core/FollowClient.swift" \
  "$here/FollowReplayTests.swift"

"$out"

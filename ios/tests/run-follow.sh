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
  "$here/../Sources/Core/Gateway/Contract/GatewayProtocol.swift" \
  "$here/../Sources/Core/Gateway/Client/GatewayTransport.swift" \
  "$here/../Sources/Core/Gateway/Client/GatewayClient.swift" \
  "$here/../Sources/Core/Secrets/CredentialStore.swift" \
  "$here/../Sources/Core/Secrets/SecretFile.swift" \
  "$here/../Sources/Core/Gateway/State/SessionMirror.swift" \
  "$here/../Sources/Core/Gateway/Stream/FailableDecodable.swift" \
  "$here/../Sources/Core/Gateway/Stream/OpeningFrame.swift" \
  "$here/../Sources/Core/RefreshGate.swift" \
  "$here/../Sources/Core/Log.swift" \
  "$here/../Sources/Core/Gateway/Stream/FollowClient.swift" \
  "$here/TestHarness.swift" \
  "$here/FollowReplayTests.swift"

"$out"

#!/bin/sh
#
# 编译并运行模型选择的协议与状态机测试（M7，V1–V4 + 解码）。
#
# 与 run.sh / run-usage.sh 同一手法：纯值类型不 import SwiftUI / UIKit，
# 编成 macOS 命令行程序跑断言。协议模型在 GatewayProtocol.swift，客户端回包
# 结构在 GatewayClient.swift（CredentialStore 只是被它引用，一并编入）。
#
# 跑法：bash ios/tests/run-model.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-model-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/Gateway/GatewayProtocol.swift" \
  "$here/../Sources/Core/Log.swift" \
  "$here/../Sources/Core/Gateway/GatewayTransport.swift" \
  "$here/../Sources/Core/Secrets/CredentialStore.swift" \
  "$here/../Sources/Core/Secrets/SecretFile.swift" \
  "$here/../Sources/Core/Gateway/GatewayClient.swift" \
  "$here/../Sources/Features/Sessions/ModelSelectionState.swift" \
  "$here/TestHarness.swift" \
  "$here/ModelProtocolTests.swift"

"$out"

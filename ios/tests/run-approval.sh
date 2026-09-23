#!/bin/sh
#
# 编译并运行审批对账的重建测试（Q1–Q7）。
#
# 零依赖：只用 swiftc。`ApprovalStore` 只 import Foundation + Combine，所以同一份
# 源码既能被 iOS target 编译，也能在这里被编成 macOS 命令行程序。
#
# 跑法：bash ios/tests/run-approval.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-approval-tests"

swiftc -O -o "$out" \
  "$here/../Sources/Core/GatewayProtocol.swift" \
  "$here/../Sources/Core/CredentialStore.swift" \
  "$here/../Sources/Core/GatewayClient.swift" \
  "$here/../Sources/Features/Approval/ApprovalStore.swift" \
  "$here/ApprovalReconcileTests.swift"

"$out"

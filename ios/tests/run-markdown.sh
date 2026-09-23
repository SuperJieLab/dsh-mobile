#!/bin/sh
#
# 编译并运行 Markdown 解析器的测试（M1–M4）。
#
# MarkdownParser 是纯状态机，不 import SwiftUI / UIKit —— 所以同一手法可用：
# 和 run.sh / run-follow.sh / run-transient.sh / run-usage.sh / run-assembler.sh
# 一样编成 macOS 命令行程序跑断言。
#
# 渲染层 `MarkdownText` 需要 SwiftUI，故不进这里 —— 它由 `swiftc -typecheck` 覆盖。
#
# 跑法：bash ios/tests/run-markdown.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${TMPDIR:-/tmp}/dsh-mobile-markdown-tests"

swiftc -O -o "$out" \
  "$here/../Sources/SharedUI/MarkdownParser.swift" \
  "$here/MarkdownParserTests.swift"

"$out"

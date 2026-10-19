/**
 * 协议错误码的取值只许出现在枚举定义处 —— 别处一律取 `.rawValue`。
 *
 * 出处：`R18-3` 的 F1。取值的集合是**闭集**：`GatewayErrorCode` 自己就是导出表，所以这条判据
 * 遍历 `allCases`，不去解析源码猜「协议里有哪些码」。这类判据在本项目有过教训 ——
 * 按语法枚举声明会被写法绕过，问「谁交出了全部取值」才是闭集。
 *
 * 扫描面与边界：
 * - 扫 `Sources/`，**排除 `Contract/`** —— 枚举的定义处就在那里，字面量本来就该出现一次。
 * - **不扫 `tests/`**：假件按上游原样写取值，让它引用我们的枚举反而会掩盖上游改动（F1 的边界）。
 * - 认的是双引号字面量整串相等（`"resync-required"`），不是子串匹配 —— 否则
 *   `"resync-required: ..."` 这类拼接文案会被误报成取值重复。
 * 盲区：三引号多行串里写成一样的整串会漏（漏报方向；取值不需要多行）。
 *
 * 跑法：`xcodebuild test -only-testing:DshMobileTests/ErrorCodeLiteralTests`。
 */
import Foundation
import XCTest

@testable import DshMobile

final class ErrorCodeLiteralTests: XCTestCase {

    /// 一个协议错误码的取值，除了 `Contract/` 之外不许在别处再写一遍。
    func testErrorCodeLiteralsStayInTheEnum() throws {
        let root = sourcesRoot.appendingPathComponent("Core")
        let files = swiftFiles(under: root)
            .filter { !$0.path.contains("/Contract/") }
        XCTAssertGreaterThan(files.count, 20, "只扫到 \(files.count) 个文件 —— 先怀疑路径推算")

        let codes = GatewayErrorCode.allCases.map { "\"\($0.rawValue)\"" }
        XCTAssertGreaterThan(codes.count, 5, "枚举交出的取值太少 —— 先怀疑 CaseIterable")

        var scannedLines = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                scannedLines += 1
                for literal in codes where code.contains(literal) {
                    let relative = file.path
                        .replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                    XCTFail("\(relative):\(line) 重写了错误码取值 \(literal)"
                            + " —— 只许取 GatewayErrorCode.x.rawValue（F1）")
                }
            }
        }
        XCTAssertGreaterThan(scannedLines, 100, "扫到的代码行太少 —— 先怀疑路径推算")
    }

    // MARK: - 路径与扫描

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
        else { return [] }
        var result: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    private func codeLines(in text: String) -> [(Int, String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    return nil
                }
                return (index + 1, String(line))
            }
    }
}

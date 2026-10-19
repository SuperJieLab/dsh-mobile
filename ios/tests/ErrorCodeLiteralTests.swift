/**
 * 协议错误码的取值只许出现在枚举定义处 —— 别处一律取 `.rawValue`。
 *
 * 取值的集合是**闭集**：`GatewayErrorCode` 自己就是导出表，所以这条判据遍历 `allCases`，
 * 不去解析源码猜「协议里有哪些码」—— 按语法枚举声明会被写法绕过。
 *
 * 扫描面与放行：
 * - 扫**整个 `Sources/`**（含 `Contract/`）：取值重写不挑目录，合约里也出现过
 *   `code: "internal-error"` 这样的兜底拷贝。
 * - 唯一放行的是**枚举定义行**（`case internalError = "internal-error"`）—— 那是取值的出处。
 *   放行按行的形状判，不按目录判。
 * - **不扫 `tests/`**：假件按上游原样写取值，让它引用我们的枚举反而会掩盖上游改动。
 * - 认双引号字面量整串相等，不是子串匹配 —— 否则 `"resync-required: …"` 这类拼接文案会被
 *   误报成取值重复。
 *
 * 盲区（漏报方向）：三引号多行串、`"resync-" + "required"` 这类拼接认不出；行内注释里出现
 * 整串会误报（把注释挪到上一行即可）。
 */
import Foundation
import XCTest

@testable import DshMobile

final class ErrorCodeLiteralTests: XCTestCase {

    /// 一个协议错误码的取值，除了枚举的定义行之外不许在别处再写一遍。
    func testErrorCodeLiteralsStayInTheEnum() throws {
        let files = swiftFiles(under: sourcesRoot)
        XCTAssertGreaterThan(files.count, 40, "只扫到 \(files.count) 个文件 —— 先怀疑路径推算")
        // 身份正控：两个必须被扫到的目录各在。目录被改名时这一条先红，而不是静默通过。
        let names = Set(files.map { $0.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "") })
        XCTAssertTrue(names.contains("Core/Gateway/Contract/GatewayProtocol.swift"), "没扫到合约")
        XCTAssertTrue(names.contains("Features/Approval/State/ApprovalStore.swift"), "没扫到界面层")

        let codes = GatewayErrorCode.allCases.map { "\"\($0.rawValue)\"" }
        XCTAssertGreaterThan(codes.count, 5, "枚举交出的取值太少 —— 先怀疑 CaseIterable")

        var scannedLines = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                scannedLines += 1
                if Self.isEnumDefinitionLine(code) { continue }
                for literal in codes where code.contains(literal) {
                    let relative = file.path
                        .replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                    XCTFail("\(relative):\(line) 重写了错误码取值 \(literal)"
                            + " —— 只许取 GatewayErrorCode.x.rawValue（F1）")
                }
            }
        }
        XCTAssertGreaterThan(scannedLines, 1000, "扫到的代码行太少 —— 先怀疑路径推算")
    }

    /// 枚举的定义行：`case internalError = "internal-error"`（可带缩进，可带 `@…` 之外的修饰）。
    private static let enumDefinition = try! NSRegularExpression(
        pattern: #"^\s*case\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*"[^"]*"\s*$"#
    )

    private static func isEnumDefinitionLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return enumDefinition.firstMatch(in: line, options: [], range: range) != nil
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

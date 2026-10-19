/**
 * 分层形状的常驻断言（R16 期1）。
 *
 * 出处：`RULES.md` §八 结构 6（同类界面分层同构；新界面必须带 `State/`）与结构 5（判定层不
 * import SwiftUI）。视图层没有单测，形状本身只能靠这几条守 —— 它们替代「收口时人工过一遍」。
 *
 * 四条：
 * 1. 每个界面目录同时有 `State/` 与 `Views/`，且 `State/` 下至少一个 `.swift`；
 * 2. `State/` 下的文件不 import SwiftUI / UIKit；
 * 3. 界面 `Views/` 下声明的类型不得被别的界面当零件用（界面根视图与登记例外除外）；
 * 4. 例外清单本身是真的（仍在某处声明、仍被别的界面引用），免得豁免悄悄扩大。
 *
 * 扫的是文本，不是语法树。已知盲区写在 `declaredTypes` 与 `firstUser` 的注释里：
 * 不认 `typealias`；缩进的嵌套声明也会被扫到（宁可误报）；注释或字符串里出现同名标识符
 * 也算引用（同样是误报方向）。误报会有人来看一眼，漏报不会。
 *
 * 跑法：`xcodebuild test -only-testing:DshMobileTests/LayeringTests`。
 */
import Foundation
import XCTest

final class LayeringTests: XCTestCase {

    // MARK: - 路径

    private var featuresRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ios/tests/
            .deletingLastPathComponent()   // ios/
            .appendingPathComponent("Sources")
            .appendingPathComponent("Features")
    }

    /// 界面目录 = `Features/` 的直接子目录。
    private func interfaceDirectories() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: featuresRoot,
                                 includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func swiftFiles(in directory: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return files.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// 递归版：`State/` 下将来若再分子目录，不该因为分层而漏扫。
    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
        else { return [] }
        var result: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// `Features/` 下全部 `.swift`（递归），用来回答「谁引用了这个名字」。
    private func allFeatureSwiftFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: featuresRoot,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
        else { return [] }
        var result: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    // MARK: - 断言 1：每个界面都有 State/ 与 Views/

    func testEveryInterfaceHasStateAndViews() throws {
        let interfaces = try interfaceDirectories()
        XCTAssertFalse(interfaces.isEmpty, "一个界面目录都没扫到：\(featuresRoot.path)")
        for interface in interfaces {
            let name = interface.lastPathComponent
            for sub in ["State", "Views"] {
                let dir = interface.appendingPathComponent(sub)
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)
                XCTAssertTrue(exists && isDirectory.boolValue,
                              "\(name) 缺少 \(sub)/ —— 同类界面必须同构（RULES §八 结构 6）")
            }
            // 空目录不算分层：文件还在旧位置上，形状是假的。
            let stateFiles = swiftFiles(under: interface.appendingPathComponent("State"))
            XCTAssertFalse(stateFiles.isEmpty, "\(name)/State/ 是空的 —— 判定与编排还没搬进来")
        }
    }

    // MARK: - 断言 2：State/ 不认识 SwiftUI

    func testStateDoesNotImportSwiftUI() throws {
        let banned = ["import SwiftUI", "import UIKit"]
        var checked = 0
        for interface in try interfaceDirectories() {
            for file in swiftFiles(under: interface.appendingPathComponent("State")) {
                checked += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    // 前缀匹配而不是整行相等：`import SwiftUI // 只为了一个 Color` 也要拦。
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if let hit = banned.first(where: { trimmed.hasPrefix($0) }) {
                        XCTFail("\(interface.lastPathComponent)/State/\(file.lastPathComponent):\(index + 1) "
                                + "出现「\(hit)」—— 判定与编排不得认识 SwiftUI（结构 5）")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "一个 State 文件都没扫到 —— 先怀疑路径推算")
    }

    // MARK: - 断言 3：Views 下的类型不被别的界面当零件用

    /// 已知的跨界面复用。每一条都要有理由，且清单本身被断言（`testExceptionsAreStillReal`）——
    /// 过期例外要删掉，不许让它悄悄扩大豁免面。
    private static let crossInterfaceExceptions: [String: String] = [
        "ApprovalCard": "审批面板物理上挂在会话详情的 composer 槽位（上游原生位置，"
            + "SessionDetailView 的底栏）；移走它会让 Approval/Views/ 变空。"
            + "重开条件：R16 期2 重划审批边界时一并决定它住哪。",
    ]

    func testViewsDeclarationsAreNotSharedAcrossInterfaces() throws {
        let interfaces = try interfaceDirectories()
        let allFiles = allFeatureSwiftFiles()
        // 每个文件只读一次：外层按界面遍历，内层按类型名找引用。
        let texts = try allFiles.map { ($0, try String(contentsOf: $0, encoding: .utf8)) }
        var scanned = 0

        for interface in interfaces {
            let interfaceName = interface.lastPathComponent
            for file in swiftFiles(in: interface.appendingPathComponent("Views")) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for type in Self.declaredTypes(in: text) {
                    scanned += 1
                    // 界面根视图可以被别的界面当「子界面」用（列表在未配对时顶上配对屏）。
                    if type == interfaceName + "View" { continue }
                    if Self.crossInterfaceExceptions[type] != nil { continue }
                    let user = firstUser(of: type, in: texts, excluding: interface)
                    if let user {
                        XCTFail("\(interfaceName)/Views/\(file.lastPathComponent) 的 \(type) 被 \(user) 引用"
                                + " —— 共用零件应住 SharedUI/（结构 4：目录名 = 模块归属）")
                    }
                }
            }
        }
        // 阳性读数：解析失效（正则写错、路径推算错）时这一条会先红，而不是让上面静默通过。
        XCTAssertGreaterThan(scanned, 0, "一个 Views 声明都没解析出来 —— 先怀疑正则或路径")
    }

    func testExceptionsAreStillReal() throws {
        let interfaces = try interfaceDirectories()
        let allFiles = allFeatureSwiftFiles()
        let texts = try allFiles.map { ($0, try String(contentsOf: $0, encoding: .utf8)) }

        for (type, reason) in Self.crossInterfaceExceptions {
            var homestead: URL?
            for interface in interfaces {
                for file in swiftFiles(in: interface.appendingPathComponent("Views")) {
                    let text = try String(contentsOf: file, encoding: .utf8)
                    if Self.declaredTypes(in: text).contains(type) { homestead = interface }
                }
            }
            guard let homestead else {
                XCTFail("例外 \(type) 已不再声明于任何 Views/ 下 —— 删掉这条例外（理由原写：\(reason)）")
                continue
            }
            let user = firstUser(of: type, in: texts, excluding: homestead)
            XCTAssertNotNil(user, "例外 \(type) 已不再被其它界面引用 —— 删掉这条例外（理由原写：\(reason)）")
        }
    }

    // MARK: - 扫描工具

    /// 声明名。跳过 `private` / `fileprivate` —— 它们按定义出不了本文件。
    ///
    /// 盲区：只认行首（允许前导空白，所以**缩进的嵌套声明也会被扫到** —— 误报方向，接受）；
    /// 不认 `typealias`。跨界面用一个类型必须写出它的名字，而这个名字来自某个非 private
    /// 声明 —— 所以漏报不会放过这类失败模式。
    private static let declaration = try! NSRegularExpression(
        pattern: #"^(?:@[A-Za-z0-9_]+[ \t]+)?(?:(?:public|internal|final|open)[ \t]+)*"#
            + #"(?:struct|class|enum|actor|protocol)[ \t]+([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static func declaredTypes(in text: String) -> [String] {
        var names: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("private ") || trimmed.hasPrefix("fileprivate ") { continue }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = declaration.firstMatch(in: trimmed, options: [], range: range),
                  let nameRange = Range(match.range(at: 1), in: trimmed)
            else { continue }
            names.append(String(trimmed[nameRange]))
        }
        return names
    }

    /// 第一个出现该名字的**其它界面**文件（返回「界面/文件」形式，便于定位）。
    ///
    /// 按裸文本匹配：注释与字符串里出现的名字也算 —— 误报方向，接受。别的界面里**声明**同名
    /// 类型同样算命中：两个界面各有一个同名类型，读者本来就分不清在说哪一个。
    private func firstUser(of name: String,
                           in texts: [(URL, String)],
                           excluding interface: URL) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
        for (url, text) in texts where !url.path.hasPrefix(interface.path + "/") {
            guard text.range(of: pattern, options: .regularExpression) != nil else { continue }
            let file = url.lastPathComponent
            let owner = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            return "\(owner)/\(file)"
        }
        return nil
    }
}

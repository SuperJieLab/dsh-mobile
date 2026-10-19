/**
 * 分层形状与依赖方向的常驻断言 —— 十五条，逐条见各 `test` 的文档注释。
 *
 * 守三件事：依赖方向单向、同类界面分层同构、目录名不能同时给出两个承诺。
 * 视图层与目录边界都没有单测，形状本身只能靠这几条守，它们替代「收口时人工过一遍」。
 *
 * 扫的是文本，不是语法树。已知盲区：
 * - 不认 `typealias`（漏报方向）；
 * - 方向检查只取**顶层**类型名（内层同名会互相误报；跨层引用嵌套类型必须写出外层名字，
 *   所以不漏）；嵌套声明在界面检查里仍会被扫到（宁可误报）；
 * - 只跳过整行注释，行内注释与字符串里出现同名标识符也算引用（误报方向）；
 * - 中文检查按行判：代码行尾的行内注释会被误报；显示口径的符号名单是手维护的。
 *
 * 误报会有人来看一眼，漏报不会 —— 所以宁可多报。
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

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private var wireDirectory: URL {
        sourcesRoot.appendingPathComponent("Core/Gateway/Wire")
    }

    private var sharedUIDirectory: URL {
        sourcesRoot.appendingPathComponent("SharedUI")
    }

    /// 线上形状不许认识的三层：客户端、流、状态。
    private var gatewayImplementationDirectories: [URL] {
        ["Client", "Stream", "State"].map { sourcesRoot.appendingPathComponent("Core/Gateway/\($0)") }
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
                              "\(name) 缺少 \(sub)/ —— 同类界面必须同构")
            }
            // 空目录不算分层：文件还在旧位置上，形状是假的。
            let stateFiles = swiftFiles(under: interface.appendingPathComponent("State"))
            XCTAssertFalse(stateFiles.isEmpty, "\(name)/State/ 是空的 —— 判定与编排不在这里")
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

    // MARK: - 断言 2b：Core 侧的 State/ 只装纯值类型

    /// `Core/**/State/` 只装无状态的值类型判定 —— 有状态持有者归 `Features/*/State/`。
    ///
    /// 两处同名不同义是刻意的：通信域的 `State/` 是「协议语义的纯判定」（`Equatable`、
    /// 不认识 Combine），界面域的 `State/` 是「持有并发布」。这条断言把差别钉成可判的事实，
    /// 免得有人在通信域塞一个 `ObservableObject`，让两级重新混成一件事。
    ///
    /// 盲区：`ObservableObject` 的别名（`@Observable` 宏、自定义协议）认不出。前者要宏插件，
    /// 本项目的验证环境不用；后者目前不存在。
    func testCoreStateHasNoObservableObject() throws {
        let root = sourcesRoot.appendingPathComponent("Core")
        var directories: [URL] = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return XCTFail("Core 目录没扫到：\(root.path)") }
        for case let url as URL in walker where url.lastPathComponent == "State" {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.append(url)
            }
        }
        // 身份正控：Core 侧至少有一个 State/ —— 目录被改名时这一条先红。
        XCTAssertFalse(directories.isEmpty, "Core 下一个 State/ 都没扫到：\(root.path)")

        var checked = 0
        for directory in directories {
            for file in swiftFiles(under: directory) {
                checked += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (line, code) in codeLines(in: text) where code.contains("ObservableObject") {
                    let relative = file.path
                        .replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                    XCTFail("\(relative):\(line) 出现 ObservableObject"
                            + " —— Core 侧的 State/ 只装纯值类型判定，有状态持有者归 Features/")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "一个文件都没扫到 —— 先怀疑路径推算")
    }

    // MARK: - 断言 3：Views 下的类型不被别的界面当零件用

    /// 已知的跨界面复用。每一条都要有理由，且清单本身被断言（`testExceptionsAreStillReal`）——
    /// 过期例外要删掉，不许让它悄悄扩大豁免面。
    private static let crossInterfaceExceptions: [String: String] = [
        "ApprovalCard": "审批面板物理上挂在会话详情的 composer 槽位（上游原生位置，"
            + "SessionDetailView 的底栏）；移走它会让 Approval/Views/ 变空。"
            + "重开条件：下次重划审批边界时一并决定它住哪。",
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

    // MARK: - 断言 5–7：Core 与线上形状的方向

    /// 线上形状目录里不出现 `Client/`、`Stream/`、`State/` 声明的类型。
    ///
    /// 只查**代码行**：注释里提到实现层不算违反；字符串里出现同名算命中（误报方向，接受）。
    func testWireDoesNotReferenceImplementationTypes() throws {
        let forbidden = try declaredTypes(under: gatewayImplementationDirectories, topLevelOnly: true)
        XCTAssertFalse(forbidden.isEmpty, "实现层一个类型都没扫到 —— 先怀疑路径推算")
        let files = swiftFiles(under: wireDirectory)
        XCTAssertFalse(files.isEmpty, "线上形状目录一个文件都没扫到：\(wireDirectory.path)")

        var hits = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for type in forbidden where contains(type, in: code) {
                    hits += 1
                    XCTFail("Wire/\(file.lastPathComponent):\(line) 出现 \(type)"
                            + " —— 线上形状不得依赖会变的实现")
                }
            }
        }
        XCTAssertEqual(hits, 0, "线上形状引用了实现层的类型")
    }

    /// 线上形状里的中文只能出现在注释里 —— 「用户看得见的句子」不许住在这里。
    ///
    /// 判据形态是「含中文的行必须是注释行」，不是「字面量里不许有中文」：后者要认出三引号
    /// 多行串，而最长的几段文案正是 `"""` 包着的 —— 单行引号正则对它们假绿。
    /// 盲区：代码行尾的行内注释会被误报 —— 遇到就把注释挪到上一行。
    func testWireHasNoUserFacingStrings() throws {
        let files = swiftFiles(under: wireDirectory)
        XCTAssertFalse(files.isEmpty, "线上形状目录一个文件都没扫到")

        var commentLines = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, source) in allLines(in: text) where containsHan(source) {
                let trimmed = source.trimmingCharacters(in: .whitespaces)
                let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
                    || trimmed.hasPrefix("/*")
                if isComment {
                    commentLines += 1
                    continue
                }
                XCTFail("Wire/\(file.lastPathComponent):\(line) 的中文不在注释里：\(trimmed)")
            }
        }
        XCTAssertGreaterThan(commentLines, 0, "线上形状里连中文注释都没有 —— 先怀疑路径或读取")
    }

    /// 线上形状的代码行里不出现显示口径的符号名 —— 「中文只在注释里」挡不住没有中文字面的规则
    /// （`displayMessage` 的 `"text"`、`relativeTime` 的 `zh_Hans_CN`）。
    ///
    /// 名单是手维护的：新增显示口径的符号时加一行；或者干脆放在 `Display/` —— 那样天然不会被拦。
    /// 名单的判据是「它是显示口径的符号」，与那个符号住在哪个目录无关：现在 `displayMessage`
    /// 住 `State/`，仍要拦（改住哪里都不许被线上形状引用）。
    private static let displayVocabulary = [
        "explanation", "readableDescription", "displayMessage", "relativeTime", "DisplayMessage",
    ]

    func testWireHasNoDisplayVocabulary() throws {
        let files = swiftFiles(under: wireDirectory)
        XCTAssertFalse(files.isEmpty, "线上形状目录一个文件都没扫到")

        var hits = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for name in Self.displayVocabulary where contains(name, in: code) {
                    hits += 1
                    XCTFail("Wire/\(file.lastPathComponent):\(line) 出现 \(name)"
                            + " —— 显示口径应住 Display/")
                }
            }
        }
        XCTAssertEqual(hits, 0, "线上形状里出现了显示口径的符号")
    }

    /// `Display/` 不引用实现层的类型 —— 它要能被状态层与视图复用的前提。
    func testDisplayDoesNotReferenceImplementationTypes() throws {
        let forbidden = try declaredTypes(under: gatewayImplementationDirectories, topLevelOnly: true)
        XCTAssertFalse(forbidden.isEmpty, "实现层一个类型都没扫到")
        let files = swiftFiles(under: sourcesRoot.appendingPathComponent("Core/Gateway/Display"))
        XCTAssertFalse(files.isEmpty, "Display 一个文件都没扫到")

        var hits = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for type in forbidden where contains(type, in: code) {
                    hits += 1
                    XCTFail("Display/\(file.lastPathComponent):\(line) 出现 \(type)"
                            + " —— 显示层不得反向依赖通信细节")
                }
            }
        }
        XCTAssertEqual(hits, 0, "Display 引用了实现层的类型")
    }

    /// `Core/` 下不引用 `SharedUI/` 声明的类型（呈现层的类型只许被呈现层与更外层看见）。
    func testCoreDoesNotReferenceSharedUITypes() throws {
        let forbidden = try declaredTypes(under: [sharedUIDirectory], topLevelOnly: true)
        XCTAssertFalse(forbidden.isEmpty, "SharedUI 一个类型都没扫到 —— 先怀疑路径推算")
        let files = swiftFiles(under: sourcesRoot.appendingPathComponent("Core"))
        XCTAssertFalse(files.isEmpty, "Core 一个文件都没扫到")

        var hits = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for type in forbidden where contains(type, in: code) {
                    hits += 1
                    let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                    XCTFail("\(relative):\(line) 出现 \(type)"
                            + " —— 通信层不得认识呈现层")
                }
            }
        }
        XCTAssertEqual(hits, 0, "Core 引用了 SharedUI 的类型")
    }

    // MARK: - 断言 10：视图不把取数结果接进自己

    /// 赋值右侧是 `await` —— 取数结果要落到视图上，必然先赋给属性或局部量。
    ///
    /// 守的是「取数结果、加载态与失败三面归判定层，视图只发起取数、只读三面」。改造前
    /// `ModelPickerView` 一处命中（`catalog = await sync.loadModelCatalog()`），改造后应为 0。
    ///
    /// 认三种落点：`x = await …`、`x += await …`（其余复合赋值同理）、`x = (await …)`。
    ///
    /// 盲区（都是漏报方向，写在这儿免得重修 —— 复审逐条列过）：
    /// - **结果不经过赋值**：`items.append(await f())`、`messages += await g()` 里的
    ///   `+=` 已被覆盖，但 `append(...)` / 构造器实参 / `return await f()` 认不出；
    /// - 赋值拆成两行（等号在上一行、`await` 在下一行）认不出；
    /// - 取数封装在一个返回 `Void` 的函数里认不出 —— 那恰好是本期的正当写法（状态对象自己取数）。
    ///
    /// 为什么不把「任何位置出现 `await`」都算命中：视图中正当的**发起**也是 `await`
    /// （`Task { await sync.sync() }`），那会把整条判据变成「视图不许 await」，与契约不符。
    private static let awaitedAssignment = try! NSRegularExpression(
        pattern: #"(?<!=)(?:[+\-*/%&|^]=|=)(?!=)\s*(?:try[?!]\s+)?\(?\s*await"#
    )

    func testViewsDoNotTakeFetchResults() throws {
        var scanned = 0
        var hits = 0
        for interface in try interfaceDirectories() {
            for file in swiftFiles(under: interface.appendingPathComponent("Views")) {
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (line, code) in codeLines(in: text) {
                    let range = NSRange(code.startIndex..., in: code)
                    guard Self.awaitedAssignment.firstMatch(in: code, options: [], range: range) != nil
                    else { continue }
                    hits += 1
                    XCTFail("\(interface.lastPathComponent)/Views/\(file.lastPathComponent):\(line)"
                            + " 把 await 的结果赋给了自己 —— 取数归 State/")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 0, "一个 Views 文件都没扫到 —— 先怀疑路径推算")
        XCTAssertEqual(hits, 0, "视图里还有取数赋值")
    }

    // MARK: - 断言 11–12：句子与说法不住在编排里

    /// 会话详情的编排文件里，**含中文的行必须是注释行**（或以 `Log.` 开头）——
    /// 用户看得见的句子归 `Display/SyncText.swift`，判定与编排只产出「哪一步 + 哪一类原因」。
    ///
    /// 判据形态照线上形状那几条：不认字符串字面量，改按行判。理由是**三引号多行串**——
    /// 单行引号正则对它 0 命中（复审复算过：往编排里写一段 `"""` 包着的中文，旧写法的
    /// 命中数不变）。而一段多行的用户文案正是最典型的写法之一，漏它等于没守。
    ///
    /// 只钉 `SessionSync.swift` 一个文件，不钉整个 `State/`：本屏的 `TranscriptAssembler`
    /// （过程摘要）与 `ApprovalStore`（两句提示）的文案仍在原地 —— 那是本期范围边界里写明的
    /// 「不做」，钉整个目录会让这条断言从第一天就红着。
    ///
    /// 两条豁免：
    /// - **注释行**（`//` / `///` / `*` / `/*` 开头）—— 注释本来就该是中文；
    /// - **整行以 `Log.` 开头** —— 日志文案在本项目一律写中文（`Core/Log.swift` 是唯一出口，
    ///   `SecretFile`、`TailnetNode` 都是中文），而日志不是用户看得见的面；把用户句子写进
    ///   `Log.` 里对用户没有意义。
    private var sessionSyncFile: URL {
        sourcesRoot.appendingPathComponent("Features/SessionDetail/State/SessionSync.swift")
    }

    func testSyncOrchestrationHasNoUserFacingStrings() throws {
        let text = try String(contentsOf: sessionSyncFile, encoding: .utf8)
        XCTAssertTrue(text.contains("func sync()"), "读到的不是编排文件 —— 先怀疑路径推算")

        var commentLines = 0
        var hits = 0
        for (line, source) in allLines(in: text) where containsHan(source) {
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                commentLines += 1
                continue
            }
            if trimmed.hasPrefix("Log.") { continue }
            hits += 1
            XCTFail("SessionSync.swift:\(line) 的中文不在注释里：\(trimmed)")
        }
        XCTAssertEqual(hits, 0, "编排文件里还有用户可见的句子")
        XCTAssertGreaterThan(commentLines, 0, "编排文件里连中文注释都没有 —— 先怀疑路径或读取")
    }

    /// 全部 `Display/` 目录（`Features/*/Display/` 与 `Core/**/Display/`）。
    private func displayDirectories() -> [URL] {
        guard let walker = FileManager.default.enumerator(at: sourcesRoot,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles])
        else { return [] }
        var result: [URL] = []
        for case let url as URL in walker where url.lastPathComponent == "Display" {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// `Display/` 不 import SwiftUI / UIKit —— 它是「说法与换算」的家，不是第二个 Views。
    ///
    /// 认的是「`import` 之后的模块名」，不是「以 `import SwiftUI` 开头」：后者漏掉
    /// `@_exported import SwiftUI`、`@preconcurrency import`、`import struct SwiftUI.Color`
    /// 这些写法（复审点名的三种）。
    private static let swiftUIImport = try! NSRegularExpression(
        pattern: #"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?"#
            + #"(?:SwiftUI|UIKit)\b"#
    )

    func testDisplayDoesNotImportSwiftUI() throws {
        let directories = displayDirectories()
        // 身份正控：不光数个数，还要这两个目录各在。目录被改名时这一条先红，而不是静默通过。
        let names = Set(directories.map { $0.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "") })
        XCTAssertTrue(names.contains("Core/Gateway/Display"), "没扫到 Core/Gateway/Display：\(names)")
        XCTAssertTrue(names.contains("Features/SessionDetail/Display"),
                      "没扫到 Features/SessionDetail/Display：\(names)")

        var checked = 0
        for directory in directories {
            for file in swiftFiles(under: directory) {
                checked += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (line, code) in codeLines(in: text) {
                    let range = NSRange(code.startIndex..., in: code)
                    guard let match = Self.swiftUIImport.firstMatch(in: code, options: [], range: range),
                          let found = Range(match.range, in: code)
                    else { continue }
                    XCTFail("\(directory.lastPathComponent)/\(file.lastPathComponent):\(line) "
                            + "出现「\(code[found].trimmingCharacters(in: .whitespaces))」"
                            + " —— 说法与换算不得认识 SwiftUI")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "一个 Display 文件都没扫到")
    }

    // MARK: - 断言 13–15：共用形状只有一份

    /// 「直连 / 中继」的**声明**只在连接域出现一次。
    ///
    /// 认的是「枚举 case 里的**裸**标识符」：`direct` 前面紧挨着的不是 `.`（`.direct` 是使用）。
    /// 这样三种写法都对：
    /// - `case direct` / `case relay`（分两行）
    /// - `case direct, relay`（一行两个）—— 两者都算命中，但它仍然是「一处声明」，
    ///   所以判据按**文件 + 行**去重，不按命中次数；
    /// - `case let .direct(value)` / `case CarrierPath.direct:`（模式匹配与使用）—— 前面有 `.`，
    ///   不算声明。
    ///
    /// 盲区（漏报方向）：把取值写成别的名字再映射过来（`case p2p`）认不出；用 `static let`
    /// 而不是 `case` 的常量也认不出。这两类都会在评审里被看见，不会静默。
    func testConnectionPathIsDeclaredOnce() throws {
        let files = swiftFiles(under: sourcesRoot)
        XCTAssertGreaterThan(files.count, 40, "只扫到 \(files.count) 个文件 —— 先怀疑路径推算")
        var sawCarrierPath = false

        // 按「文件 + 所属 enum」去重：一个枚举把 direct 与 relay 分两行写，仍是一处声明。
        var declarations: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("enum CarrierPath") { sawCarrierPath = true }

            var owner: String?
            for (line, code) in codeLines(in: text) {
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                if let name = Self.enumName(in: trimmed) { owner = name }

                guard trimmed.hasPrefix("case "), !trimmed.hasPrefix("case ."),
                      !trimmed.hasPrefix("case let "), !trimmed.hasPrefix("case is ")
                else { continue }
                guard Self.declaresBareCase(code, names: ["direct", "relay"]) else { continue }
                let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                let home = owner.map { "\(relative) 的 enum \($0)" } ?? "\(relative):\(line)"
                declarations.insert(home)
            }
        }
        XCTAssertTrue(sawCarrierPath, "没扫到 CarrierPath 的声明 —— 先怀疑路径推算")
        XCTAssertEqual(declarations.count, 1,
                       "「直连 / 中继」应只声明一次，实际：\(declarations.sorted())")
    }

    /// 这一行若是 `enum 名字 {`（可带修饰与协议），返回名字。
    private static let enumDeclaration = try! NSRegularExpression(
        pattern: #"^(?:@[A-Za-z0-9_]+\s+)*(?:public |internal |private |fileprivate )?"#
            + #"enum\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static func enumName(in trimmed: String) -> String? {
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = enumDeclaration.firstMatch(in: trimmed, options: [], range: range),
              let found = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        return String(trimmed[found])
    }

    /// 这一行是否把 `names` 里的某个名字当成**裸**标识符写在 `case` 里（前面不是 `.`）。
    private static func declaresBareCase(_ line: String, names: [String]) -> Bool {
        for name in names {
            var search = line.startIndex
            while let range = line.range(of: name, range: search..<line.endIndex) {
                let precededByDot = range.lowerBound > line.startIndex
                    && line[line.index(before: range.lowerBound)] == "."
                let followedByWord = range.upperBound < line.endIndex
                    && (line[range.upperBound].isLetter || line[range.upperBound].isNumber
                        || line[range.upperBound] == "_")
                if !precededByDot && !followedByWord { return true }
                search = range.upperBound
            }
        }
        return false
    }

    /// 状态机不另声明窗口 / 快照的形状 —— 它引用协议里的 `SessionPage` / `SessionSnapshot`。
    ///
    /// **只查「不许声明」，不查「有没有用上」。** 后者看着更严，实际是弱检查：入口签名里
    /// 写着 `SessionPage` 就够让「出现过」为真，而被替换成本地同形类型时（真正的失败模式）
    /// 那三个签名往往还在 —— 于是它既抓不到失败模式，又会把注释里的名字算成证据。
    /// 曾写过一个用 `text.contains` 的版本，被文件头注释满足 —— 同一个洞复发过两次；
    /// 改成逐代码行后读数会真，但结论仍是「注定为真」—— 所以整段删掉。
    ///
    /// 那「声明删了、改用本地同形类型」这个失败模式靠什么？靠编译器与本条的前半：本地类型
    /// 若叫 `Snapshot` / `Window`（前身），前半红；若换个名字，它就是一个**新造的同形类型**，
    /// 而那正是评审要看的东西 —— 这类判断写不成文本判据，写进注释比写成假绿好。
    func testMirrorUsesProtocolShapes() throws {
        let mirror = sourcesRoot.appendingPathComponent("Core/Gateway/State/SessionMirror.swift")
        let text = try String(contentsOf: mirror, encoding: .utf8)
        XCTAssertTrue(text.contains("struct SessionMirror"), "读到的不是状态机 —— 先怀疑路径推算")

        var scanned = 0
        for (line, code) in codeLines(in: text) {
            scanned += 1
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            for shape in ["Snapshot", "Window"] {
                if trimmed.hasPrefix("struct \(shape)") || trimmed.hasPrefix("enum \(shape)") {
                    XCTFail("SessionMirror.swift:\(line) 又声明了 \(shape)"
                            + " —— 用协议里的同名类型")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "状态机只扫到 \(scanned) 行 —— 先怀疑路径或读取")
    }

    /// 编排里不再逐字段构造窗口 —— 那次构造本身就是「同一形状两份」的症状。
    ///
    /// 两半都要查（只查前一半会假绿：类型删掉之后，逐字段构造那两个同名字段仍然编译通过）：
    /// - 没有 `Window(` 构造；
    /// - 编排文件里不出现「`pageStart` / `asOfSeq` / `hasOlder` 三个实参挤在同一段构造里」——
    ///   认的是这三个名字在同一行，或同一行起的连续三行内相继出现（那种搬运一定是竖着写的）。
    func testNoFieldByFieldWindowCopy() throws {
        var hits = 0
        for file in swiftFiles(under: sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) where contains("Window", in: code) {
                guard code.contains("Window(") else { continue }
                hits += 1
                let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                XCTFail("\(relative):\(line) 还在构造 Window —— 直接用 SessionPage")
            }
        }
        XCTAssertEqual(hits, 0, "还有逐字段搬运的窗口构造")

        let sync = sourcesRoot
            .appendingPathComponent("Features/SessionDetail/State/SessionSync.swift")
        let lines = try String(contentsOf: sync, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var copies = 0
        for start in 0..<max(0, lines.count - 2) {
            let triple = lines[start] + lines[start + 1] + lines[start + 2]
            let looksLikeCopy = triple.contains("pageStart:") && triple.contains("asOfSeq:")
                && triple.contains("hasOlder:")
            guard looksLikeCopy else { continue }
            copies += 1
            XCTFail("SessionSync.swift:\(start + 1) 起三行内又在逐字段构造窗口"
                    + " —— 用 opening.page / SessionPage")
        }
        XCTAssertEqual(copies, 0, "编排里还有三个字段的搬运")
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

    // MARK: - 方向检查用的扫描工具

    /// 递归收集若干目录下声明的类型名。
    ///
    /// `topLevelOnly` 用于方向检查：内层同名类型（`TailnetNode.MeshPath` 与
    /// `ConnectionBadge.MeshPath`）会互相误报；而跨层引用一个嵌套类型必须写出它的外层名字，
    /// 外层名字本身就在集合里 —— 所以只取顶层不会漏。
    private func declaredTypes(under directories: [URL], topLevelOnly: Bool = false) throws -> [String] {
        var names: [String] = []
        for directory in directories {
            for file in swiftFiles(under: directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                names.append(contentsOf: topLevelOnly
                             ? Self.topLevelTypes(in: text)
                             : Self.declaredTypes(in: text))
            }
        }
        return names
    }

    /// 顶格声明的类型名（嵌套类型有前导空白，被排除）。
    private static func topLevelTypes(in text: String) -> [String] {
        var names: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, first != " ", first != "\t" else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = declaration.firstMatch(in: trimmed, options: [], range: range),
                  let nameRange = Range(match.range(at: 1), in: trimmed)
            else { continue }
            names.append(String(trimmed[nameRange]))
        }
        return names
    }

    /// 全部行（含注释），返回 (行号, 原文)。
    private func allLines(in text: String) -> [(Int, String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { ($0.offset + 1, String($0.element)) }
    }

    /// 代码行：跳过整行注释，返回 (行号, 原文)。
    ///
    /// 行内注释不剥 —— 要正确剥掉得先认出字符串里的 `//`，那是词法器的活；
    /// 宁可多报（会有人来看一眼），不可漏报。
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

    private func contains(_ name: String, in text: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// 单行双引号字面量。盲区：三引号多行串、转义引号。
    private static let stringLiteral = try! NSRegularExpression(pattern: #""([^"\\]|\\.)*""#)

    private func quotedLiterals(in line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        return Self.stringLiteral.matches(in: line, options: [], range: range)
            .compactMap { Range($0.range, in: line).map { range in String(line[range]) } }
    }

    private func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}

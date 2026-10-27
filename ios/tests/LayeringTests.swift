/**
 * 分层形状与依赖方向的常驻断言，逐条见各 `test` 的文档注释。
 *
 * 守三件事：依赖方向单向、同类界面分层同构、目录名不能同时给出两个承诺。
 * 视图层与目录边界都没有单测，形状本身只能靠这几条守，它们替代「收口时人工过一遍」。
 * 条数不写在这里：每加一条都要回改的数字迟早会漂。
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

    /// 线上形状不许认识的实现层：一元调用、长连接（WS + 流）、事件流收端。
    /// 纯判定不在此列 —— 它住消费方。
    ///
    /// ⚠️ 这四个目录名是**字面量**：改名时这里不会编译失败，
    /// 而扫不到的目录只回空数组 ⇒ 判据静默缩水、仍然全绿。改名后必须回扫这一处。
    private var gatewayImplementationDirectories: [URL] {
        ["LongConnection", "Identity", "Rpc", "Events"]
            .map { sourcesRoot.appendingPathComponent("Core/Gateway/\($0)") }
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
        swiftFiles(under: featuresRoot)
    }

    // MARK: - 断言 1：每个页面域都有 State/；Views/ 若存在必须非空

    /// 目录有 `Views/` ⟺ 它是一个**界面**；没有则它是**域**（只有事实与文案）。
    ///
    /// 渲染件跟着「唯一消费它的屏」走，不跟着值域走 —— 同一条规则在仓库里已有两个先例
    /// （`SessionRow` 渲染线上形状、`MessageBubble` 渲染显示模型，都住在各自那一屏）。
    /// 审批就是这个形状：表与文案住 `Features/Approval/`（App 级、跨屏存活），
    /// 卡片住会话详情（它只有那一个展示位置）。
    ///
    /// 两半都查，缺一样就假绿：
    /// - `State/` 必须存在且非空 —— 判定与编排永远有家；
    /// - `Views/` 若存在必须非空 —— 空目录不是界面（文件还在旧位置上，形状是假的）。
    func testEveryFeatureHasStateAndViewsAreNeverEmpty() throws {
        let interfaces = try interfaceDirectories()
        XCTAssertFalse(interfaces.isEmpty, "一个目录都没扫到：\(featuresRoot.path)")
        var withViews = 0
        for interface in interfaces {
            let name = interface.lastPathComponent
            var isDirectory: ObjCBool = false

            let stateDir = interface.appendingPathComponent("State")
            let stateExists = FileManager.default.fileExists(atPath: stateDir.path,
                                                             isDirectory: &isDirectory)
            XCTAssertTrue(stateExists && isDirectory.boolValue, "\(name) 缺少 State/")
            XCTAssertFalse(swiftFiles(under: stateDir).isEmpty,
                           "\(name)/State/ 是空的 —— 判定与编排不在这里")

            let viewsDir = interface.appendingPathComponent("Views")
            let viewsExist = FileManager.default.fileExists(atPath: viewsDir.path,
                                                            isDirectory: &isDirectory)
            guard viewsExist && isDirectory.boolValue else { continue }
            withViews += 1
            XCTAssertFalse(swiftFiles(under: viewsDir).isEmpty,
                           "\(name)/Views/ 是空的 —— 空的 Views 不是界面，删掉它")
        }
        XCTAssertGreaterThan(withViews, 2, "带 Views/ 的目录太少 —— 先怀疑路径推算")
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

    // MARK: - 断言 2b：会话视图的纯判定只装值类型

    /// 会话视图的三件纯判定（会话镜像、未定稿帧通道、消息取舍）只装 `struct` 与 `enum` ——
    /// 判定层出现引用型可变状态，就是「持有并发布」混进了纯判定。
    ///
    /// **按文件名单点名，不按目录扫**：三件的家 `Features/SessionDetail/State/` 里同住
    /// `SessionSync` 等持有者 —— 整目录扫会误伤。名单就是「这几件是纯判定」这个决定的可判
    /// 形式；名单自带存在性正控：文件改名或删掉时先红，防扫描面静默缩水。
    ///
    /// 认三类标志，覆盖同一种失败的不同写法：
    /// - `class` / `actor` —— 引用型，可能有可变状态。这是最根本的一条：一个不遵任何协议的
    ///   `final class Cache` 也能装可变状态；`@Observable` 的类型同样是 `class`，由这条一并拦下。
    /// - `import SwiftUI` / `UIKit` / `Combine` / `Observation` —— 值类型判定不需要它们；
    ///   出现即说明这一层开始认识界面或响应式框架。
    ///
    /// 盲区：行内注释里出现上述词会误报 —— 误报方向，接受。第四件同型判定加进来时要记得进名单。
    private static let sessionViewJudgments = [
        "SessionMirror.swift", "TransientChannel.swift", "MessageDisplay.swift",
    ]

    func testSessionViewJudgmentsHoldOnlyValueTypes() throws {
        let home = sourcesRoot.appendingPathComponent("Features/SessionDetail/State")
        let banned = ["class ", "actor ",
                      "import SwiftUI", "import UIKit", "import Combine", "import Observation"]
        var checked = 0
        for name in Self.sessionViewJudgments {
            let file = home.appendingPathComponent(name)
            // 存在性正控：名单里的文件必须在 —— 没了就红。少了它，名单少一行只是少扫一个文件。
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                XCTFail("名单里的 \(name) 不在 Features/SessionDetail/State/ —— 改名或删除后必须同轮改名单")
                continue
            }
            checked += 1
            for (line, code) in codeLines(in: text) {
                guard let hit = banned.first(where: { code.contains($0) }) else { continue }
                XCTFail("Features/SessionDetail/State/\(name):\(line) 出现「\(hit.trimmingCharacters(in: .whitespaces))」"
                        + " —— 这三件是纯判定（struct / enum），有状态持有者归 Features/*/State/ 的持有者们")
            }
        }
        XCTAssertEqual(checked, Self.sessionViewJudgments.count,
                       "名单有 \(Self.sessionViewJudgments.count - checked) 件没扫到 —— 先看上面的 XCTFail")
    }

    /// 旧观察机制不许回来：`ObservableObject` / `@Published` / `import Combine` 全仓零命中。
    ///
    /// 两套机制并存的代价是「不刷新」无法归因 —— 一次重算可能是对象级的，也可能是属性级的。
    /// 所以这不是风格偏好，是迁移完成后要一直守的那条边界。
    func testNoObservableObjectLeftovers() throws {
        let banned = ["ObservableObject", "@Published", "import Combine"]
        var hits: [String] = []
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for needle in banned where code.contains(needle) {
                    hits.append("\(file.lastPathComponent):\(line) \(needle)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "扫到的源码文件太少 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [], "旧观察机制又出现了：\(hits)")
    }

    /// `Core/` 下不许有 `State/` —— 通信域的承诺是「无产品行为」：纯判定住消费方，
    /// 通信域里出现判定目录就是这条承诺失守。
    func testCoreHasNoStateDirectory() throws {
        let root = sourcesRoot.appendingPathComponent("Core")
        var found: [String] = []
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return XCTFail("Core 目录没扫到：\(root.path)") }
        for case let url as URL in walker where url.lastPathComponent == "State" {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                found.append(url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: ""))
            }
        }
        XCTAssertEqual(found, [], "Core 下又出现了 State/ —— 纯判定归消费方：\(found)")
    }

    // MARK: - 断言：通信域的订阅面不出现业务概念

    /// 注册口只认「名字 + 载荷 + 代次」：方法名与参数里出现会话列表增量、待答调用、撤回
    /// 这一族词，就是「加一种业务货物要改通信域」的开始，「无产品行为」的承诺随之失守。
    ///
    /// 判据落在**注册口的声明行**（`func on…`）上：名字不许命中业务词表，参数不许是业务
    /// 形状。词表手维护 —— 新增业务词汇时加一行。
    /// 正控：通用货物口 `onCargo` 必须真的被扫到 —— 扫描失效时词表零命中会被读成合规。
    ///
    /// 盲区：只认声明行；用变量间接注册的写法靠评审。
    private static let businessSubscriptionWords = [
        "SessionList", "Approval", "Waterfall", "Cancel",
    ]

    func testCoreHasNoBusinessSubscriptions() throws {
        let root = sourcesRoot.appendingPathComponent("Core/Gateway")
        var genericHits = 0
        var hits: [String] = []
        for file in swiftFiles(under: root) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                guard code.contains("func on") else { continue }
                if code.contains("func onCargo(") { genericHits += 1 }
                for word in Self.businessSubscriptionWords where code.contains(word) {
                    hits.append("Core/Gateway/\(file.lastPathComponent):\(line) \(word)")
                }
            }
        }
        XCTAssertGreaterThan(genericHits, 0, "onCargo 一处都没扫到 —— 先怀疑扫描面")
        XCTAssertEqual(hits, [], "Core 的注册口出现了业务概念：\(hits)")
    }

    // MARK: - 断言 2c：Core 内部不反向依赖

    /// `Core/` 内部各域只许向下依赖：`MeshNetwork` 是顶层编排（`MeshStore` 编织载体与协议），
    /// 协议层不得认识它。
    ///
    /// 表只写「谁不许认识谁」，不写允许的方向 —— 允许的边比禁止的多得多，而每写一条
    /// 允许都是一次判断；不写就默认自由，坏了由这条断言抓住。新增一个域时默认不受限，
    /// 直到有人确认它该在哪一层。
    ///
    /// `Core/` 顶层的四个小值（`CarrierPath` / `Log` / `PerfRecord` / `RefreshGate`）与
    /// `MarkdownParser` 不属于任何域，不在本表的约束内 —— 它们的存在就是为了让三方共用时
    /// 不必互相认识。
    ///
    /// **域内那一条边由目录表表达不出来**：载体（`TailnetNode` / `MeshConfig` /
    /// `TailnetURLSession`）与编排（`MeshStore` / `MeshPhase`）同住 `MeshNetwork`，
    /// 而「载体不得认识编排」是域内的方向 —— 它落在 `testMeshCarrierDoesNotKnowTheOrchestrator`。
    private static let coreUpwardBans: [String: [String]] = [
        // 协议层只需要一个 URLSession，不需要认识组网这一域的任何类型。
        "Gateway": ["MeshNetwork"],
    ]

    func testCoreDomainsDoNotDependOnUpwardDomains() throws {
        let core = sourcesRoot.appendingPathComponent("Core")
        var scanned = 0

        for (domain, banned) in Self.coreUpwardBans.sorted(by: { $0.key < $1.key }) {
            let forbidden = try declaredTypes(
                under: banned.map { core.appendingPathComponent($0) }, topLevelOnly: true)
            XCTAssertFalse(forbidden.isEmpty,
                           "\(domain) 的禁止名单一个类型都没扫到 —— 先怀疑路径推算")
            let files = swiftFiles(under: core.appendingPathComponent(domain))
            XCTAssertFalse(files.isEmpty, "\(domain) 一个文件都没扫到 —— 先怀疑路径推算")

            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (line, code) in codeLines(in: text) {
                    scanned += 1
                    for type in forbidden where contains(type, in: code) {
                        let relative = file.path
                            .replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                        XCTFail("\(relative):\(line) 出现 \(type)"
                                + " —— \(domain) 是下层，不得认识 \(banned.sorted().joined(separator: " / "))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "只扫到 \(scanned) 行 —— 先怀疑路径推算")
    }

    // MARK: - 断言 2d：组网域内，载体不认识编排

    /// `MeshNetwork` 里装了两层：**载体**（谁能连上隧道）与**编排**（`MeshStore` 把节点状态、
    /// 身份、传输收敛成一个阶段）。载体不得认识编排 —— 反过来才是它该有的方向。
    ///
    /// 为什么单列一条：这两层的先后关系是**域内的**方向，而上面那张表按目录表达，
    /// 表达不了同一个目录里的两层。合并两域时如果不补这条，那条禁令就静默消失了。
    ///
    /// 豁免编排自己的三个文件（`MeshStore` / `MeshPhase` / `MeshStoreAdapters`）：前两个是
    /// 编排本身，第三个是「真实类型实现窄面」的一行声明（它必须同时看得见两侧）。
    /// 它们的依赖方向由 `coreUpwardBans` 里「协议层不认识组网」那条反向兜住。
    func testMeshCarrierDoesNotKnowTheOrchestrator() throws {
        let mesh = sourcesRoot.appendingPathComponent("Core/MeshNetwork")
        let orchestrator = ["MeshStore", "MeshPhase", "MeshNodeControlling"]
        let exempt: Set<String> = ["MeshStore.swift", "MeshStoreAdapters.swift", "MeshPhase.swift"]

        let files = swiftFiles(under: mesh).filter { !exempt.contains($0.lastPathComponent) }
        XCTAssertGreaterThanOrEqual(files.count, 4, "只扫到 \(files.count) 个载体文件 —— 先怀疑路径推算")
        // 正控：豁免名单里的文件必须真的存在，否则「扫了 4 个」可能只是把编排也扫漏了。
        for name in exempt {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: mesh.appendingPathComponent(name).path), "豁免的 \(name) 不在 —— 先怀疑路径")
        }

        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for type in orchestrator where contains(type, in: code) {
                    hits.append("\(file.lastPathComponent):\(line) \(type)")
                }
            }
        }
        XCTAssertEqual(hits, [], "载体认识了编排层（方向反了）：\(hits)")
    }

    // MARK: - 断言 2c：Core 不认识界面层的类型

    /// `Core/` 是下层，不得出现 `Features/` 下任何类型名。
    ///
    /// 与上面那张 `coreUpwardBans` 分工不同：那张表管 Core **内部**四个域互相不许向上，
    /// 本条管 Core 整体不许向上到界面层。两句都来自「依赖方向单向」这条规则，但方向不同 ——
    /// 塞进一张表里，改错一个会静默放过另一个。
    ///
    /// **为什么需要它**：讨论「把票的维护上移到配对功能」时才发现，那个做法在依赖方向上是
    /// 违规的，而**当时没有任何断言会因此变红**。判据不是给已经写对的人看的，是给下一次
    /// 想图省事的人看的。
    ///
    /// 落在**代码行**上而不是文件全文：Core 里有多处注释在解释「谁消费我」（`RefreshGate`
    /// 写 `SessionSync`、`WebSocketConnection` 写 `SessionSync`），那些提及是必要的说明，不是依赖。
    func testCoreDoesNotReferenceFeatureTypes() throws {
        let core = sourcesRoot.appendingPathComponent("Core")
        let featureTypes = try declaredTypes(under: try interfaceDirectories(), topLevelOnly: true)

        // 正控 1：名单非空 —— 空名单会让内层循环一次都不执行，判据恒真。
        XCTAssertGreaterThan(featureTypes.count, 20,
                             "只扫到 \(featureTypes.count) 个界面层类型 —— 先怀疑路径推算")

        var scanned = 0
        var hits: [String] = []
        for file in swiftFiles(under: core) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                scanned += 1
                for type in featureTypes where contains(type, in: code) {
                    let relative = file.path
                        .replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                    hits.append("\(relative):\(line) 出现 \(type)")
                }
            }
        }
        // 正控 2：真的扫了东西。Core 现在约两千行代码，阈值取一半 —— 路径推算坏了会先红在这里。
        XCTAssertGreaterThan(scanned, 1_500, "只扫到 \(scanned) 行 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [],
                       "Core 是下层，不得认识界面层的类型：" + hits.joined(separator: " / "))
    }

    // MARK: - 断言 2d：票的过期判定只有一处

    /// 「访问票什么时候过期」全仓只有一处判断 —— 在 `TicketKeeper` 里。
    ///
    /// 这条替代不了审查，但它挡住一类会重演的事：票的判定被第二个地方复制一份（读缓存的一处、
    /// 发起请求的一处），于是「本地认为还有效、另一处认为过期」在运行时看不出来。同型的先例
    /// 是 `Menu` 与 `Picker` 各算一遍选中项，屏幕上勾与值对不上。
    ///
    /// 判据落在**比较表达式**上而不是字段名：`RpcMessages.swift` 里那个 `expiresAt: Double?`
    /// 是协议字段（解码必须还在），`RpcClient` 里那行把它换成 `Date` 也是必要的一步
    /// —— 两者都不做比较。
    func testOnlyOnePlaceComparesTicketExpiry() throws {
        let core = sourcesRoot.appendingPathComponent("Core")
        var comparisons: [(file: String, line: Int)] = []

        for file in swiftFiles(under: core) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, code) in codeLines(in: text) {
                // 比较运算符左右涉及 expiresAt 才算出局：`now < issued.expiresAt`、
                // `expiresAt > now`、`expiresAt <= …` 都算。
                guard code.contains("expiresAt") else { continue }
                let pattern = try NSRegularExpression(pattern: #"(<|>|<=|>=)\s*[\w.]*expiresAt|expiresAt\s*(<|>|<=|>=)"#)
                let range = NSRange(code.startIndex..., in: code)
                if pattern.firstMatch(in: code, range: range) != nil {
                    comparisons.append((file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: ""), number))
                }
            }
        }

        // 正控：这一条必须真的扫到东西，否则「零处比较」会被读成「合规」。
        XCTAssertEqual(comparisons.count, 1,
                       "访问票的过期比较应当只有一处（TicketKeeper），实际："
                       + comparisons.map { "\($0.file):\($0.line)" }.joined(separator: " / "))
        XCTAssertEqual(comparisons.first?.file,
                       "Core/Gateway/Identity/TicketKeeper.swift",
                       "过期判定该住在票那一层，不是别处")
    }

    // MARK: - 断言 2d：落盘基建只有一份，且它是基建

    /// `Core/SecretFile.swift` 是**唯一的落盘基建**（按名字存/取/删一个字符串），
    /// 且它只认识字节，不认识任何具体凭证。
    ///
    /// 两个方向：
    /// 1. **只有一份基建** —— 第二个「按名字写文件」的实现出现时有第二份路径拼法、第二份
    ///    文件保护设置、第二份失败日志；其中最要紧的那条（写失败必须留痕）会各写一遍。
    /// 2. **基建里不出现具体凭证名** —— `"device-token"` / `"tailnet-key"` 属于业务包装。
    ///    一旦出现，说明这里已经开始认识别人的概念，那个名字该归回自己的域。
    ///
    /// 判据落在**这个文件**上而不是目录：容器能被建出来，就能重新积进别人的东西 ——
    /// 盯住文件本身，「`Core/` 顶层的落盘基建只该是这一个」才是可验的事实。
    func testSecretFileIsTheOnlyStoragePrimitive() throws {
        let file = sourcesRoot.appendingPathComponent("Core/SecretFile.swift")
        // 正控：文件必须真的在，否则下面的读取会抛错，而「零违规」会被读成合规。
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "Core/SecretFile.swift 不在 —— 先怀疑路径推算")

        let text = try String(contentsOf: file, encoding: .utf8)
        // 正控 2：确实是那个基建。删了一半或换了内容时，下面两条会「零命中」通过。
        XCTAssertTrue(text.contains("enum SecretFile"), "这个文件里没有 SecretFile —— 先怀疑读错了文件")

        var names: [String] = []
        for credential in ["device-token", "tailnet-key"] where text.contains("\"\(credential)\"") {
            names.append(credential)
        }
        XCTAssertEqual(names, [],
                       "落盘基建里出现了具体凭证名 —— 名字属于业务包装，基建只接受一个参数")

        // 第二个方向：Core 顶层不该再有一个「按名字写文件」的邻居。
        // 判据是它做的事（写 Data 到 Application Support），不是文件名。
        let coreTop = swiftFiles(in: sourcesRoot.appendingPathComponent("Core"))
        var duplicates: [String] = []
        for other in coreTop where other.lastPathComponent != "SecretFile.swift" {
            let body = try String(contentsOf: other, encoding: .utf8)
            if body.contains("completeFileProtection") {
                duplicates.append(other.lastPathComponent)
            }
        }
        XCTAssertEqual(duplicates, [],
                       "Core 顶层有第二份落盘基建（也设了 completeFileProtection）：\(duplicates)")
    }

    // MARK: - 断言 2e：网关出口只发请求，不认识 op

    /// 请求构造点：`XxxRequest(` 这类**具名**请求的构造。
    ///
    /// 排除 `URLRequest(` —— 那是 Foundation 的载体，不是协议的 op。这条排除写在这里而不是
    /// 每次判断：它是个固定的事实，散在判据里迟早会有一处漏掉。
    private static func builtRequests(in code: String) -> [String] {
        // 左边界排除 `onXxxRequest(` 这类方法名 —— 它含 `XxxRequest(`，但没有
        // 构造任何东西。没有这个边界时，给端口加一个 `onXxxRequest` 回调就会变成一条假红。
        guard let pattern = try? NSRegularExpression(pattern: #"(?<![A-Za-z])([A-Z][A-Za-z]*Request)\("#) else { return [] }
        let range = NSRange(code.startIndex..., in: code)
        return pattern.matches(in: code, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: code) else { return nil }
            let name = String(code[r])
            // `URLRequest(` 是 Foundation 的载体；其余都是协议的 op。
            return name == "URLRequest" ? nil : name
        }
    }

    /// `RpcClient` 只许构造**换票**这一个请求。
    ///
    /// 失败模式是「图省事把某个 op 加回出口」—— 同一个 op 于是有两个入口，而调用方不知道
    /// 哪个才是现在用的那个。判据落在这一份文件里出现的请求构造上，白名单只有换票一条
    /// （身份的另一半是「建立关系」，那一步不发请求，只收 `adopt` 的一个字符串）；
    /// 正控保证正则没失灵（换票请求必须真的被扫到）。
    func testRpcClientConstructsOnlyTheRenewalRequest() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/Rpc/RpcClient.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let built = codeLines(in: text).flatMap { Self.builtRequests(in: $0.1) }

        XCTAssertTrue(built.contains("RefreshRequest"), "没扫到 RefreshRequest —— 先怀疑正则：\(built)")

        XCTAssertEqual(Set(built).subtracting(["RefreshRequest"]), [],
                       "RpcClient 里出现了业务请求 —— op 归用到它的那个功能，加回出口就有了两个入口")
    }

    /// 请求只在 `State/` 里拼：视图不直接把一条协议请求交给网关。
    ///
    /// `Wire/` 是形状的出处、`Rpc/` 收身份那两个，两处都排除；其余的构造点全仓都在
    /// `*/State/` 下。判据同时数一遍构造点（正控），免得路径或正则坏了之后变成「零违规」。
    func testRequestsAreBuiltInStateLayersOnly() throws {
        var offenders: [String] = []
        var built = 0
        for file in swiftFiles(under: sourcesRoot) {
            let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            if relative.hasPrefix("Core/Gateway/Wire/")
                || relative.hasPrefix("Core/Gateway/Rpc/")
                || relative.hasPrefix("Core/Gateway/LongConnection/Wire/") {
                continue
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            var here: [String] = []
            for (_, code) in codeLines(in: text) {
                here += Self.builtRequests(in: code)
            }
            guard !here.isEmpty else { continue }
            built += here.count
            if !relative.contains("/State/") { offenders.append(relative) }
        }
        XCTAssertGreaterThan(built, 5, "全仓只扫到 \(built) 处请求构造 —— 先怀疑路径或正则")
        XCTAssertEqual(offenders.sorted(), [],
                       "这些文件在 State/ 之外拼请求 —— 取数与下发归状态层：\(offenders)")
    }

    // MARK: - 断言 3：Views 下的类型不被别的界面当零件用

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

    // MARK: - 断言 5–7：Core 与线上形状的方向

    /// 实现层的每个目录都必须真的扫到文件，根上的两件与失败词汇的住处必须真的存在。
    ///
    /// 守的是下面各条判据的**盲区**：目录名是字面量，`swiftFiles(under:)` 对不存在的目录
    /// 回空数组、不抛错 ⇒ 改名时漏改一处，判据只是少扫一层而照样全绿（`Client/` → `Rpc/`
    /// 那次真实发生过）。
    func testEveryGatewayImplementationDirectoryIsFound() {
        for directory in gatewayImplementationDirectories {
            XCTAssertFalse(swiftFiles(under: directory).isEmpty,
                           "\(directory.lastPathComponent)/ 扫不到任何 .swift —— 目录改名了？")
        }
        for name in ["LongConnection/LongConnection.swift", "LongConnection/Backoff.swift",
                     "Rpc/RpcClientError.swift"] {
            let file = sourcesRoot.appendingPathComponent("Core/Gateway/\(name)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                          "\(name) 不在 —— 守卫名单与实际住处不一致")
        }
    }

    /// 装配层站根：流层与传输层的目录里出现它，就是「门又长回了实现层」。
    ///
    /// 两个方向一起扫：流层不站装配（门与租户分名），传输层也不引用装配（依赖方向单向）。
    /// 正控：根上的装配文件必须真的扫到造流入口 —— 空集会被读成合规。
    func testTheHostStaysOutOfTheStreamLayer() throws {
        let host = try String(
            contentsOf: sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/LongConnection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(host.contains("func makeStream"), "装配的造流入口没扫到 —— 判据可能扫错了树")

        var hits: [String] = []
        for name in ["LongConnection/Stream", "LongConnection/WebSocket"] {
            for file in swiftFiles(under: sourcesRoot.appendingPathComponent("Core/Gateway/\(name)")) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (line, code) in codeLines(in: text) where code.contains("LongConnection") {
                    hits.append("\(file.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertEqual(hits, [], "实现层出现了装配层 —— 它站根：\(hits)")
    }

    /// 线上形状目录里不出现实现层（`LongConnection/`、`Identity/`、`Rpc/`、`Events/`）声明的类型。
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

    /// 三件线上形状各只有一处声明，且都在 `Wire/MuxFrames.swift` —— 与网关 `wire/mux.ts` 按名对看。
    ///
    /// 失败模式是「另写一份刚好够用的」：形状散在使用处时，两端各写一份且互不相认，改字段
    /// 那一侧靠回忆或 grep 发现。判据按**声明**数，不按引用数 —— 引用本来就会有多处，
    /// 而重复声明才是那一份新的形状。
    ///
    /// **逐个文件认 `struct` 而不是用 `declaredTypes(in:)`**：那个函数跳过 `private` /
    /// `fileprivate`，而「另写一份刚好够用的」有一种写法恰好是 `private struct` —— **嵌套在
    /// 某个类型里**（不同作用域，编译器不报重复声明）。顶格的同名重复由编译器挡（`invalid
    /// redeclaration`），嵌套的那一份只有这条判据看得见。
    ///
    /// 声明位置的断言与网关的文件名对应：形状出现在 `Wire/` 之外就红。
    /// 判据自带正控：三个名字一个都没扫到时，下面的比较会以一个空的实测值对上一份非空期望。
    ///
    /// 盲区：只认 `struct`。写成 `typealias FollowRequest = …` 或包在条件编译分支里认不出
    /// （漏报方向，靠评审）。
    func testWireShapesAreDeclaredOnce() throws {
        let shapes = ["MuxServerEnvelope", "MuxOpenFrame", "MuxCancelFrame", "FollowRequest",
                      "EventsRequest", "OpeningFrame"]
        var homes: [String: [String]] = [:]

        for file in swiftFiles(under: sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            for (_, code) in codeLines(in: text) {
                for shape in shapes where Self.declaresStruct(shape, in: code) {
                    homes[shape, default: []].append(relative)
                }
            }
        }

        for shape in shapes {
            XCTAssertEqual(homes[shape], ["Core/Gateway/LongConnection/Wire/MuxFrames.swift"],
                           "\(shape) 应只有一处声明且在 Wire/MuxFrames.swift，实际：\(homes[shape] ?? [])")
        }
    }

    /// 这一行是否声明了 `struct <name>`（允许前面带访问修饰）。
    private static func declaresStruct(_ name: String, in line: String) -> Bool {
        guard let pattern = try? NSRegularExpression(
            pattern: "\\bstruct\\s+" + NSRegularExpression.escapedPattern(for: name) + "\\b")
        else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return pattern.firstMatch(in: line, options: [], range: range) != nil
    }

    /// 这一行是否声明了名为 `name` 的类型（`struct` / `class` / `enum` / `protocol`）。
    private static func declaresType(_ name: String, in line: String) -> Bool {
        for keyword in ["struct", "class", "enum", "protocol"] {
            guard let pattern = try? NSRegularExpression(
                pattern: "\\b" + keyword + "\\s+" + NSRegularExpression.escapedPattern(for: name) + "\\b")
            else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if pattern.firstMatch(in: line, options: [], range: range) != nil { return true }
        }
        return false
    }

    /// 根 `Wire/` 只放载荷：信封（`*Request` / `*Response` / `GatewayResponse`）住 `Rpc/Wire/`。
    ///
    /// 判据是「信封带 `v` / `ok` / `err`，只在 HTTP 出现」—— 放在根 `Wire/` 会让读代码的人
    /// 以为流也能发请求。正控：`Rpc/Wire/` 必须真的扫到信封，否则这条判据只是扫了个空。
    func testRootWireHoldsNoEnvelopes() throws {
        let wire = sourcesRoot.appendingPathComponent("Core/Gateway/Wire")
        let files = swiftFiles(under: wire)
        // 正控：扫空目录时 hits 恒为空 —— 「零命中」与「目录没了」同形。
        XCTAssertGreaterThanOrEqual(files.count, 6, "根 Wire/ 只扫到 \(files.count) 个文件")
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in Self.declaredTypes(in: text)
            where name.hasSuffix("Request") || name.hasSuffix("Response") || name == "GatewayResponse" {
                hits.append("\(file.lastPathComponent) \(name)")
            }
        }
        XCTAssertEqual(hits, [], "根 Wire/ 出现了信封：\(hits)")

        let rpcWire = sourcesRoot.appendingPathComponent("Core/Gateway/Rpc/Wire")
        let names = try swiftFiles(under: rpcWire).flatMap {
            Self.declaredTypes(in: try String(contentsOf: $0, encoding: .utf8))
        }
        XCTAssertTrue(names.contains("GatewayResponse"), "Rpc/Wire/ 没扫到信封 —— 先怀疑路径")
    }

    /// 身份只有一个出处：`CredentialStore.deviceToken`。
    ///
    /// 守「已配对 ≡ 有设备凭证」。若别处再存一份 `isPaired`，它就要靠手工同步维持 ——
    /// 绕过同步点写一次凭证，盘上有、界面说没有，而编译不报错、断言也不红。
    ///
    /// 断法：全仓不存在 `var isPaired: Bool` 的**存值**声明。计算属性与闭包可以
    ///（`var isPaired: Bool { hasIdentity() }` 是读穿，不是副本）。
    func testIdentityHasNoSecondCopy() throws {
        var hits: [String] = []
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                scanned += 1
                // 存值两种写法：`var isPaired: Bool`（行尾）与 `var isPaired: Bool = …`。
                // 计算属性是 `var isPaired: Bool { … }` —— 带花括号，不在下面两条之内。
                let storedBare = code.range(
                    of: "var\\s+isPaired\\s*:\\s*Bool\\s*$", options: .regularExpression) != nil
                let storedInit = code.range(
                    of: "var\\s+isPaired\\s*:\\s*Bool\\s*=", options: .regularExpression) != nil
                if storedBare || storedInit { hits.append("\(relative):\(line)") }
            }
        }
        XCTAssertGreaterThan(scanned, 1000, "扫到的行太少 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [], "这些地方存着一份 isPaired —— 身份只有 CredentialStore 一处")
    }

    /// 设置页的依赖面不认识请求层。
    ///
    /// 身份与解除都以闭包注入。视图拿到 `RpcClient` 就知道怎么发请求（那是禁的），而这一层
    /// 也不需要知道 —— 它要的只是「有没有身份」与「断开关系」两件事。
    func testSettingsStateHoldsNoClient() throws {
        let file = sourcesRoot.appendingPathComponent("Features/Settings/State/SettingsState.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))
        XCTAssertGreaterThan(lines.count, 10, "只扫到 \(lines.count) 行 —— 先怀疑路径推算")

        // 正控：确认读到了本体，否则下面的零命中守的是空气。
        XCTAssertTrue(lines.contains { $0.1.contains("func unlink()") }, "没读到 unlink")
        let hits = lines.filter { $0.1.contains("RpcClient") }.map { "\($0.0)" }
        XCTAssertEqual(hits, [], "设置页的依赖面认识了请求层：\(hits)")
    }

    /// 票必须晚于凭证消亡：凭证没了，手上那张票也不许还活着。
    ///
    /// 只删凭证不清票会留下一个窗口 —— 请求带着未过期的票照常成功，而用户以为关系已经解除。
    /// 两半分别住在 `CredentialStore` 与 `TicketKeeper`，只有 `RpcClient` 同时持有两者，
    /// 所以这条判据落在那个跨两层的动作上。
    func testTicketDiesWithCredential() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/Rpc/RpcClient.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))

        // 正控：先确认读到了那个动作，否则下面的「两行相邻」守的是空气。
        let start = try XCTUnwrap(lines.first { $0.1.contains("func discardIdentity(") }?.0,
                                  "没读到 discardIdentity —— 先怀疑改名")
        let body = lines.filter { $0.0 > start && $0.0 <= start + 6 }
        XCTAssertTrue(body.contains { $0.1.contains("deleteDeviceToken") },
                      "discardIdentity 里必须删凭证")
        XCTAssertTrue(body.contains { $0.1.contains("tickets.clear") },
                      "discardIdentity 里必须清票 —— 只删凭证会留下「有票没凭证」的窗口")
    }

    /// 隧道的产物只有一个主人：`MeshStore.route`。
    ///
    /// 守的是「一个事实一个存放处」。地址与传输是同一件事的两半（组网激活那一刻的产物），
    /// 分开存就会出现「有地址但传输已作废」「换了传输但地址还是老的」这类中间态 ——
    /// 症状是「切了组网仍往老地址打」，只在真机上表现为连不上，本地全绿。
    ///
    /// **两半一起断**：① 全仓只有一个文件声明这两个值的存值属性；② 那个文件是
    /// `MeshStore.swift` —— 产物住在判据那一侧，才谈得上「跟着判据失效」。
    ///
    /// ⚠️ 这条靠**具体文件名**找落点：`MeshStore.swift` 改名后必须同轮改这里。
    func testTheTunnelProductHasOneOwner() throws {
        let owner = "Core/MeshNetwork/MeshStore.swift"
        let bannedFile = "Core/Gateway/Endpoint.swift"
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sourcesRoot.appendingPathComponent(bannedFile).path),
            "\(bannedFile) 又出现了 —— 产物只许住 MeshStore（第二个存放处会漂）")

        var stores: [String: [Int]] = [:]
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                scanned += 1
                // 只认**存值**的声明。取数的闭包（`baseURL: () -> URL?`）不算 ——
                // 它是「怎么问」，恰恰是接缝该有的形态。
                let storesURL = code.contains("baseURL: URL")
                    && !code.contains("baseURL: () ->")
                    && !code.contains("baseURL: @escaping")
                let storesSession = code.contains("session: URLSession")
                    && !code.contains("session: () ->")
                    && !code.contains("session: @escaping")
                if storesURL || storesSession { stores[relative, default: []].append(line) }
            }
        }
        XCTAssertGreaterThan(scanned, 1000, "扫到的行太少 —— 先怀疑路径推算")

        // 正控：产物确实被找到了，否则下面的「只有一个主人」守的是空气。
        XCTAssertEqual(stores[owner]?.count, 2,
                       "\(owner) 里应有两处产物存值（session / baseURL），实际 \(stores[owner] ?? [])")
        // 反向：别处一处都不许有。
        let intruders = stores.filter { $0.key != owner }
        XCTAssertEqual(intruders, [:], "这些地方还自己存着地址或传输：\(intruders)")
    }

    /// 消息条数只从**已组装的显示节点**数，不从原始事件另算一遍。
    ///
    /// 同一件事两个出处会漂：`nodes` 是界面真正渲染的东西，另一份 `[DisplayMessage]`
    /// 若与它不同步（少一个过滤、多一次去重），footer 说「3 条消息」而屏上只有 2 条，
    /// 而两者都「看起来对」。
    ///
    /// 也不只是正确性 —— 从原始事件重算要为**窗口里每个事件**构造一次 `DisplayMessage`
    ///（含字符串拼接），而这些结果只用 `.count`。
    func testMessageCountComesFromAssembledNodes() throws {
        let sync = sourcesRoot.appendingPathComponent(
            "Features/SessionDetail/State/SessionSync.swift")
        let lines = codeLines(in: try String(contentsOf: sync, encoding: .utf8))

        // 正控：确认读到了本体与刷新点。
        XCTAssertTrue(lines.contains { $0.1.contains("func refreshView()") }, "没读到刷新点")

        // 不许再有一份 `[DisplayMessage]` 的发布属性，也不许再从事件里 compactMap 它。
        let shape = "compactMap(" + "\\" + ".displayMessage)"
        let offenders = lines.filter {
            $0.1.contains("var messages") || $0.1.contains(shape)
        }.map { $0.0 }
        XCTAssertEqual(offenders, [], "又从事件另算了一份消息：行 \(offenders)")

        // 消息条数要能从组装结果数出来。
        let assembler = sourcesRoot.appendingPathComponent(
            "Features/SessionDetail/State/TranscriptAssembler.swift")
        let aLines = codeLines(in: try String(contentsOf: assembler, encoding: .utf8))
        XCTAssertTrue(aLines.contains { $0.1.contains("case message(") },
                      "TranscriptNode 里没有 message 形态 —— 数不出来了")
    }

    /// 一个类型不许同时被视图与流层消费。
    ///
    /// 两端的消费者各有一个标记：`@Observable` 意味着有视图在读它的属性，
    /// `StreamBehavior` 意味着流层（Core）拿它当帧判读器。同一个类型同时是两者，就把
    /// 「改流层判读协议」与「改视图状态」绑在一起 —— 改一边要动另一边，而两边根本不相关。
    ///
    /// **`@Observable` 不是 conformance**：它是属性宏，写在类型声明上一行，所以按
    /// 「`@Observable` 行 + 紧随的 class 声明」配对识别，不能复用 `conformedTypes`。
    ///
    /// 判据自带正控：两个集合都必须非空，否则交集永远为空。
    func testNoTypeIsBothViewStateAndStreamBehavior() throws {
        var viewStates: Set<String> = []
        var streamBehaviors: Set<String> = []

        for file in swiftFiles(under: sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = codeLines(in: text)
            viewStates.formUnion(Self.observableTypes(in: lines))
            for (_, code) in lines {
                for name in Self.conformedTypes(conformingTo: "StreamBehavior", in: code) {
                    streamBehaviors.insert(name)
                }
            }
        }

        XCTAssertFalse(viewStates.isEmpty, "一个 @Observable 类型都没扫到 —— 先怀疑正则")
        XCTAssertFalse(streamBehaviors.isEmpty, "一个 StreamBehavior 都没扫到 —— 先怀疑正则")

        let both = viewStates.intersection(streamBehaviors).sorted()
        XCTAssertEqual(both, [],
                       "这些类型同时被视图与流层消费：\(both) —— 判读器要单独一个类型")
    }

    /// 标了 `@Observable` 的类型名：属性行在前，`class` 声明紧随其后（中间没有别的声明）。
    private static func observableTypes(in lines: [(Int, String)]) -> Set<String> {
        var out: Set<String> = []
        var sawAttribute = false
        for (_, code) in lines {
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            if trimmed == "@Observable" { sawAttribute = true; continue }
            guard sawAttribute else { continue }
            let pattern = "^(?:final\\s+)?class\\s+(\\w+)"
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: trimmed,
                                     range: NSRange(trimmed.startIndex..<trimmed.endIndex,
                                                    in: trimmed)),
               let r = Range(m.range(at: 1), in: trimmed) {
                out.insert(String(trimmed[r]))
            }
            sawAttribute = false
        }
        return out
    }

    /// 这一行里 conform 了 `protocol` 的类型名。认三种写法：
    /// `final class X: P`、`extension X: P`、`struct X: P, Q`。
    private static func conformedTypes(conformingTo proto: String, in line: String) -> [String] {
        let pattern = "\\b(?:class|struct|enum|extension)\\s+(\\w+)\\s*:[^{]*\\b"
            + NSRegularExpression.escapedPattern(for: proto) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return re.matches(in: line, options: [], range: range).compactMap { m in
            Range(m.range(at: 1), in: line).map { String(line[$0]) }
        }
    }

    /// 状态源为流层适配器开的门**恰好两扇**，且顺序是「先应用、再记性能」。
    ///
    /// 门开得越窄越好：把 `mirror` / `transient` 也交出去，适配器就能绕过判读直接改镜像，
    /// 而「一帧怎么变成屏幕上的变化」立刻出现第二个决策者。
    ///
    /// 顺序也是判据的一部分：先记性能再应用，会把「应用到哪一步」记成「收到」——
    /// 两者之差正是这一跳的耗时，颠倒了这条时延数据就没有意义。
    func testTheBehaviorGetsExactlyTwoDoors() throws {
        let stateSource = sourcesRoot.appendingPathComponent(
            "Features/SessionDetail/State/SessionSync.swift")
        let lines = codeLines(in: try String(contentsOf: stateSource, encoding: .utf8))

        // 正控：确认读到了本体。
        XCTAssertTrue(lines.contains { $0.1.contains("class SessionSync") }, "没读到状态源")

        // 只为适配器开放的两个入口（`internal`，不带 `private`）。
        let doors = ["func apply(_ reading: StreamReading)",
                     "func recordPerf(_ reading: StreamReading"]
        for door in doors {
            XCTAssertTrue(lines.contains { $0.1.contains(door) },
                          "入口不见了：\(door)")
        }

        // 适配器里两个调用的先后。
        let behavior = sourcesRoot.appendingPathComponent(
            "Features/SessionDetail/State/SessionBehavior.swift")
        let bLines = codeLines(in: try String(contentsOf: behavior, encoding: .utf8))
        let applyAt = bLines.first { $0.1.contains("owner.apply(") }?.0
        let perfAt = bLines.first { $0.1.contains("owner.recordPerf(") }?.0
        let applyLine = try XCTUnwrap(applyAt, "适配器没调 apply")
        let perfLine = try XCTUnwrap(perfAt, "适配器没调 recordPerf")
        XCTAssertLessThan(applyLine, perfLine, "先应用、再记性能 —— 顺序颠倒时延数据就错了")
    }

    /// 构造是一条链：**没有「先塞假值、稍后替换」的中间态**。
    ///
    /// 判据只看一件事：`TicketKeeper` 在全仓只有**一个**构造点，且那个构造点的实参不是
    /// 「恒返回等一等」的假动作。占位写法（`TicketKeeper { _ in .retryLater }` 打底、
    /// `init` 末尾再赋值）会让「票层是假的」成为一个真实可达的阶段 —— 那段时间里任何
    /// 要票的路径都静默拿到「等一等」。
    ///
    /// 换成 `lazy` 之后这条仍成立：一个定义、一个构造点，首次用时求值。
    func testTheTicketsHaveOneRealConstructionSite() throws {
        var sites: [String] = []
        var fakes: [String] = []
        for file in swiftFiles(under: sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            // 认**构造**的形态（`= TicketKeeper {`），不认类声明那一行（`class TicketKeeper {`）。
            for (line, code) in codeLines(in: text) where code.contains("= TicketKeeper {") {
                sites.append("\(relative):\(line)")
                if code.contains("retryLater") { fakes.append("\(relative):\(line)") }
            }
        }
        XCTAssertEqual(sites.count, 1, "票层应只有一个构造点，实际：\(sites)")
        XCTAssertEqual(fakes, [], "构造点用了假动作（先占位后替换的形态）：\(fakes)")
    }

    /// 裸发层不认识票 —— 它只认识地址、字节与怎么算失败。
    ///
    /// 这一条守的是那个死锁的结构面：若裸发层能读票，它就有办法在换票那一发上带票，
    /// 而带票会让票闸回头问票、等在自己那一趟上。行为面由
    /// `RpcClientAuthTests.testTheRefreshCallItselfCarriesNoTicket` 守着，两条一起才够 ——
    /// 结构面管「写不出来」，行为面管「真跑起来确实没带」。
    func testTheBareTransportKnowsNoTicket() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/Rpc/HttpTransport.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))
        XCTAssertGreaterThan(lines.count, 20, "只扫到 \(lines.count) 行 —— 先怀疑路径推算")

        // 正控：这个文件里确实有发送口，否则下面的「零命中」守的是空气。
        XCTAssertTrue(lines.contains { $0.1.contains("func send") }, "没扫到发送口")

        // 认的是「票这件事」：票的类型、票的生命周期、带不带票的开关。
        // 不认 `unauthenticated` —— 那是身份失败的**词汇**（`RpcClientError` 的一个 case），
        // 裸发层要判「服务端说没身份」就必须能说这个词，它与「此刻手上有没有一张票」无关。
        // `RpcClient` 也在名单里：持有一个门面就等于能问它要票 —— 那是恢复
        // 「等自己那一趟」的最短路径。但 `RpcClientError` 要排除：那是**失败词汇**
        // 而不是票源，裸发层判成败必须能说它（`RpcClientError.unauthenticated`）。
        let forbidden = ["AccessTicket", "TicketKeeper", "tickets",
                         "authenticated:", "authenticated ?", "authenticated)"]
        var hits: [String] = []
        for (line, code) in lines {
            for word in forbidden where code.contains(word) {
                hits.append("\(line) \(word)")
            }
            // 门面名单独判：剥掉 `RpcClientError` 再找 `RpcClient`。
            let stripped = code.replacingOccurrences(of: "RpcClientError", with: "")
            if stripped.contains("RpcClient") { hits.append("\(line) RpcClient") }
        }
        XCTAssertEqual(hits, [], "裸发层认识了票：\(hits)")
    }

    /// 「组网通了、换路由」与「回前台、要一条连接」不许同名。
    ///
    /// 两者都在同一个装配文件里被调用，字面完全一样时，读代码的人只能靠参数分辨哪个是哪个。
    /// 断的是**带参数的那个形态**：要连接那个没有参数，它不受这条约束。
    func testRouteUpdateIsNotNamedActivate() throws {
        let files = swiftFiles(under: sourcesRoot)
        XCTAssertGreaterThan(files.count, 50, "只扫到 \(files.count) 个文件 —— 先怀疑路径推算")
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            for (line, code) in codeLines(in: text) where code.contains("func activate(session:") {
                hits.append("\(relative):\(line)")
            }
        }
        XCTAssertEqual(hits, [], "换路由不该叫 activate：\(hits)")
    }

    /// 身份不属任何一条链路：`Identity/` 不出现任一链路的类型与线路；长连接源码零 `RpcClient`。
    ///
    /// 两半一起断：① `Identity/` 只认识「票」与「设备凭证」；② 长连接只收闭包 ——
    /// 收类型就等于把整台一元客户端抱进来（那正是它为了取票认识三百行的由来）。
    func testIdentityBelongsToNeitherLink() throws {
        let identity = sourcesRoot.appendingPathComponent("Core/Gateway/Identity")
        let files = swiftFiles(under: identity)
        XCTAssertGreaterThanOrEqual(files.count, 2, "Identity/ 只扫到 \(files.count) 个文件")

        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for word in ["RpcClient", "WebSocketConnection", "URLSession", "LongConnection"]
                where code.contains(word) {
                    hits.append("\(file.lastPathComponent):\(line) \(word)")
                }
            }
        }
        XCTAssertEqual(hits, [], "Identity/ 认识了某条链路：\(hits)")

        let file = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/LongConnection.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))
        XCTAssertFalse(lines.contains { $0.1.contains("RpcClient") }, "长连接认识了整台一元客户端")
    }

    /// WebSocket 层认不出流层的任何词汇，也不动流表。
    ///
    /// 两半一起断：① 类型名零命中 —— 它连「流」这个概念都不该出现；② `mux.` 零命中 ——
    /// 收帧改成交给注入的闭包之后，连接层对流表一个成员都不该访问。
    ///
    /// 扫描面是两处：`WebSocket/`（`Channel` 住那里）与 `Connection/`（连接本体住那里）。
    /// 两处都要扫，否则「扫空目录回空数组」会让这条判据静默变绿。
    /// 正控：文件数少于预期时先怀疑路径推算。
    func testTheWebSocketLayerKnowsNoStreamVocabulary() throws {
        let roots = webSocketLayerRoots
        let streamVocabulary = ["StreamMux", "LogicalStream", "StreamBehavior",
                                "StreamFactory", "StreamReply", "StreamPort"]
        var scanned = 0
        var nameHits: [String] = []
        var muxHits: [String] = []

        for root in roots {
            for file in swiftFiles(under: root) {
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                for (line, code) in codeLines(in: text) {
                    for name in streamVocabulary where code.contains(name) {
                        nameHits.append("\(relative):\(line) \(name)")
                    }
                    if code.contains("mux.") { muxHits.append("\(relative):\(line)") }
                }
            }
        }

        // 门槛按**文件数**而不是下限：少一个文件就说明扫描面缺了一块。
        XCTAssertGreaterThanOrEqual(scanned, 3, "只扫到 \(scanned) 个文件 —— 先怀疑路径推算")
        XCTAssertEqual(nameHits, [], "WebSocket 层出现了流层词汇：\(nameHits)")
        XCTAssertEqual(muxHits, [], "WebSocket 层还在访问流表：\(muxHits)")
    }

    /// WebSocket 层的扫描面：`Channel` 与连接本体同住 `WebSocket/`。
    private var webSocketLayerRoots: [URL] {
        ["Core/Gateway/LongConnection/WebSocket"]
            .map { sourcesRoot.appendingPathComponent($0) }
    }

    /// 装配只有一处：造流表、接 `Channel`、接收帧闭包都在统筹对象里各一次。
    ///
    /// 三个接点各自失败的症状不同，所以各断各的：漏 `attach` ⇒ 事件没人听（换代次不重开）；
    /// 漏 `onFrame` ⇒ 帧全被丢掉（界面永远空）；漏 `onGenerationChange` 的订阅在流表里，
    /// 由 `StreamMuxTests` 那条行为判据守着。
    func testTheWiringHappensInOnePlaceOnly() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/LongConnection.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))

        XCTAssertEqual(lines.filter { $0.1.contains("attach(channel:") }.count, 1,
                       "Channel 只在一处接上")
        XCTAssertEqual(lines.filter { $0.1.contains("onFrame =") }.count, 1,
                       "收帧闭包只在一处接上")
        XCTAssertEqual(lines.filter { $0.1.contains("makeStream(") && !$0.1.contains("func ") }.count, 1,
                       "造流口只转发一次")
    }

    /// 两个反应由流层订阅：连接层只发事件，不直接动流表。
    ///
    /// 两半都要断：只删调用不补发出，行为会静默消失（换代次后流不重开）；只补发出不删调用，
    /// 等于同一件事有两条路径（换号两次）。所以「调用没了」与「发出点各一个」写在一起。
    func testTheConnectionEmitsInsteadOfTouchingTheTable() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/WebSocket/WebSocketConnection.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))

        XCTAssertFalse(lines.contains { $0.1.contains("mux.reopenAll(") },
                       "重新开流由事件触发，不由连接层调用")
        XCTAssertFalse(lines.contains { $0.1.contains("mux.closeAll(") },
                       "清表同理")
        XCTAssertEqual(lines.filter { $0.1.contains("onGenerationChange?()") }.count, 1,
                       "换代次只在这一处发出")
        XCTAssertEqual(lines.filter { $0.1.contains("onStopped?()") }.count, 1,
                       "停用只在这一处发出")
    }

    /// 流层的声明各住一处：`StreamMux.swift` 只留流表**与它那一行**。
    ///
    /// 为什么 `LogicalStream` 不单独住一个文件：它的六个可变字段（编号 / 文本 / 退避档位 /
    /// 在途标记 / 是否开过 / 在途尝试）是 `fileprivate` —— 只有同一个文件里的流表能写，
    /// 编译器替「业务侧改不到它们」把关。拆开就必须放宽成 `internal`，等于用一条编译期保证
    /// 换目录整洁。所以这里钉的是
    /// 「别把跨层那个令牌也塞回来」：`StreamAttempt` 不掌握任何可变状态，住自己的文件。
    ///
    /// 失败模式：跨层声明与流表挤在一起时，读文件的人分不清哪些是「表的行为」、
    /// 哪些只是它旁边放着的形状。
    ///
    /// 判据自带正控：扫描面的文件数少于预期时先怀疑路径推算（扫空目录回空数组，
    /// 零命中与合规同形）。
    func testTheStreamLayerDeclarationsHaveOneHomeEach() throws {
        let expected: [String: [String]] = [
            "StreamMux": ["Core/Gateway/LongConnection/Stream/StreamMux.swift"],
            "LogicalStream": ["Core/Gateway/LongConnection/Stream/StreamMux.swift"],
            // 父级：WebSocket 层生成它、流层用它对等比较，两层共守（见该文件头）。
            "StreamAttempt": ["Core/Gateway/LongConnection/StreamAttempt.swift"],
            "Channel": ["Core/Gateway/LongConnection/WebSocket/Channel.swift"],
        ]
        let root = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection")
        let files = swiftFiles(under: root)
        var homes: [String: [String]] = [:]

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            for (_, code) in codeLines(in: text) {
                for name in expected.keys where Self.declaresType(name, in: code) {
                    homes[name, default: []].append(relative)
                }
            }
        }

        XCTAssertGreaterThanOrEqual(files.count, 9,
                                    "只扫到 \(files.count) 个文件 —— 目录改名了？")
        for (name, home) in expected {
            XCTAssertEqual(homes[name], home,
                           "\(name) 应只有一处声明且在 \(home)，实际：\(homes[name] ?? [])")
        }
    }


    /// 开流帧**按 op 点名**拼装：每一类开流只有一处拼装点，且每一处都在清单写下的位置。
    ///
    /// 旧写法只认 `MuxOpenFrame.following(` 一个 marker：第二类开流帧（`events(`）加进来之后
    /// 它照样全绿 ——「一处拼装」这条纪律对新增的那一类一点都没生效。清单因此改成
    /// 「op → 文件」，并且**清单自己也断**：源码里出现第三个工厂而清单没登记时，最后一条红。
    ///
    /// 拼装点住在状态层与 App 级容器，所以形状判据只能以「点名一处」的方式容纳它们：
    /// 豁免要写出坐标，坐标对不上（清单里那个文件不再构造，或别处也构造）就红。
    func testOpenFramesAreBuiltInDeclaredPlaces() throws {
        let declared: [(op: String, file: String)] = [
            ("following", "Features/SessionDetail/State/SessionBehavior.swift"),
            ("events", "Core/Gateway/Events/EventStream.swift"),
        ]
        var files: [(relative: String, code: [(Int, String)])] = []
        for file in swiftFiles(under: sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            files.append((relative, codeLines(in: text)))
        }

        for item in declared {
            let marker = "MuxOpenFrame.\(item.op)("
            let homes = Set(files.filter { entry in
                entry.code.contains { $0.1.contains(marker) }
            }.map { $0.relative })
            XCTAssertEqual(homes, Set([item.file]),
                           "`\(marker)` 的拼装点不在清单里：\(homes.sorted())")
        }

        // 清单自身：源码里出现、而清单没认领的工厂 → 红。否则「再加一类开流」静默绕过它。
        //
        // 扫**整段文本**而不是逐行，也不要求工厂名紧跟 `(`：换行书写（`MuxOpenFrame` 一行、
        // `.events(...)` 下一行）与「先取成员引用再调」都是真实存在的写法，按行按括号会把
        // 它们当成没出现 —— 而这正是这条判据唯一要抓的东西。
        //
        // 盲区：根本不经过工厂、自己拼 `{"type":"open",...}` 字面量的形态扫不到。那个方向
        // 只能由「`Wire/MuxFrames.swift` 是唯一的开流帧构造入口」这条纪律挡着，靠评审。
        let factory = try NSRegularExpression(pattern: "MuxOpenFrame\\s*\\.\\s*([A-Za-z_][A-Za-z0-9_]*)")
        var found: Set<String> = []
        for file in swiftFiles(under: sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in factory.matches(in: text, range: range) {
                if let name = Range(match.range(at: 1), in: text) {
                    found.insert(String(text[name]))
                }
            }
        }
        XCTAssertEqual(found, Set(declared.map { $0.op }),
                       "有拼装点没登记在清单里（扫到为空也走这条）：\(found.sorted())")
    }

    /// 传输层不认识帧内容 —— 它的代码行里数不出 op 名、帧类型取值、协议错误码、会话字段。
    ///
    /// 判据按**词**扫，注释行不算：注释里可以讲这些词，那是在解释别人的形状。四条一起守，
    /// 因为它们是同一件事的四种写法 —— 少守一条，另一种写法就能把业务知识写进这一层。
    ///
    /// 盲区：只认字面量与裸标识符。用变量间接比较（`let kind = "it" + "em"`）抓不到，那种
    /// 写法靠评审；也可能误判 —— 本层若真需要这些词，说明职责又长回去了。
    func testTransportKnowsNoFrameContent() throws {
        let dir = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/WebSocket")
        let lines = try swiftFiles(under: dir).flatMap { file -> [(Int, String)] in
            codeLines(in: try String(contentsOf: file, encoding: .utf8))
        }
        let forbidden = [
            "\"follow\"", "\"item\"", "\"end\"", "\"error\"", "\"usage\"", "\"approval\"",
            "GatewayErrorCode", "sessionId",
        ]

        var hits: [String] = []
        for (number, code) in lines {
            for word in forbidden where code.contains(word) {
                hits.append(":\(number) \(word)")
            }
        }

        XCTAssertGreaterThan(lines.count, 100, "扫到的代码行太少 —— 先怀疑路径或切行")
        XCTAssertEqual(hits, [], "传输层出现了帧内容的词汇（它只该答「线还在不在」）：\(hits)")
    }

    // MARK: - 断言：流层与传输层的边界

    /// 流层既不向上认识传输层，也不向外认识业务的词汇与协议错误码。
    ///
    /// 四条一起守，因为它们是同一件事的四种写法：认识 socket 原语、认识具体传输类型、
    /// 认识协议错误码、按 op 名分支 —— 少守一条，另一种写法就能把上层或外层的知识带到这里。
    ///
    /// 正控：文件里必须仍有 `func makeStream(`，否则说明扫错了文件（零命中读成合规）。
    func testStreamLayerLooksNeitherUpNorOut() throws {
        let dir = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/Stream")
        let lines = try swiftFiles(under: dir).flatMap { file -> [(Int, String)] in
            codeLines(in: try String(contentsOf: file, encoding: .utf8))
        }
        let forbidden = [
            "URLSession", "WebSocketConnection", "Unscoped", "GatewayErrorCode",
            "\"follow\"", "\"events\"", "握手", "心跳", "代次",
        ]

        XCTAssertTrue(lines.contains { $0.1.contains("func makeStream(") },
                      "没找到 `func makeStream(` —— 先怀疑路径或改名")
        XCTAssertGreaterThan(lines.count, 80, "扫到的代码行太少 —— 先怀疑路径或切行")

        var hits: [String] = []
        for (number, code) in lines {
            for word in forbidden where code.contains(word) {
                hits.append(":\(number) \(word)")
            }
        }
        XCTAssertEqual(hits, [], "流层出现了它不该认识的东西（它只该认编号与答复）：\(hits)")
    }

    /// 传输层不造编号、不建表 —— 它不认识「一条流」这个概念，只把整帧交出去。
    ///
    /// 正控：文件里必须有流通道的路径常量，否则说明扫错了文件。
    func testTransportMintsNoIdsAndKeepsNoTable() throws {
        let dir = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/WebSocket")
        let lines = try swiftFiles(under: dir).flatMap { file -> [(Int, String)] in
            codeLines(in: try String(contentsOf: file, encoding: .utf8))
        }
        let forbidden = ["newStreamId", "[StreamId:", "Map<StreamId", "openInFlight", "byId"]

        XCTAssertTrue(lines.contains { $0.1.contains("\"/rpc/stream\"") },
                      "没找到流通道路径 —— 先怀疑路径或改名")
        XCTAssertGreaterThan(lines.count, 100, "扫到的代码行太少 —— 先怀疑路径或切行")

        var hits: [String] = []
        for (number, code) in lines {
            for word in forbidden where code.contains(word) {
                hits.append(":\(number) \(word)")
            }
        }
        XCTAssertEqual(hits, [], "传输层开始管流了（它只该答「线还在不在」）：\(hits)")
    }

    /// 无编号帧的收货人不进流层的签名：它不属于任何一条流。
    ///
    /// 这一条单独守，因为它与上面那张单元表方向相反 —— 收货人是「连接级」的，
    /// 一旦它出现在流层，就会有人给某条流代收，而「归谁」随之变成登记顺序的函数。
    func testUnscopedFramesNeverEnterTheStreamLayer() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/Stream/StreamMux.swift")
        let text = try String(contentsOf: file, encoding: .utf8)

        XCTAssertTrue(text.contains("final class StreamMux"), "先怀疑路径或改名")
        XCTAssertFalse(text.contains("Unscoped"), "流层出现了无编号帧的收货人")
    }

    /// 一条流的可变状态只有流表能写：四个字段声明成 `fileprivate(set)`，构造入口
    /// 是 `fileprivate init` —— 于是「业务侧改不到编号 / 档位 / 在途标记」由编译器守，
    /// 而不是靠一条 grep 判据。
    ///
    /// 这条判据守的是**声明的形状**：有人把 `fileprivate(set)` 放宽成 `internal(set)`，
    /// 编译器就不再拦，而这行字是唯一会红的信号。
    func testStreamStateIsOnlyWritableByTheStreamTable() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/Stream/StreamMux.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = codeLines(in: text)
        let body = try XCTUnwrap(block(startingAt: "final class LogicalStream", in: lines),
                                 "没找到 LogicalStream 的类型体 —— 先怀疑路径或改名")

        for field in ["var id: StreamId", "var text: String", "var retryAttempt",
                      "var openInFlight", "var attempt: StreamAttempt?"] {
            XCTAssertTrue(body.contains { $0.1.contains("fileprivate(set) \(field)") },
                          "\(field) 不是 fileprivate(set) —— 业务侧就能改它")
        }
        XCTAssertTrue(body.contains { $0.1.contains("fileprivate init(") },
                      "构造入口不是 fileprivate —— 业务侧能造出一个不在表里的流")
    }

    /// 两条业务流都只经**同一个造流口**接上流层：会话详情与连接级事件流平级。
    ///
    /// 这一条守的是「平级」这个承诺的形状：任何一条被特殊对待（自己拼开流文本、
    /// 自己持有传输层、走另一条入口），两者就不再同构，而用户看不出区别。
    func testBothBusinessStreamsUseTheSameFactory() throws {
        let session = sourcesRoot
            .appendingPathComponent("Features/SessionDetail/State/SessionSync.swift")
        let events = sourcesRoot
            .appendingPathComponent("Core/Gateway/Events/EventStream.swift")

        for (name, url) in [("会话详情", session), ("事件流", events)] {
            let lines = codeLines(in: try String(contentsOf: url, encoding: .utf8))
            XCTAssertTrue(lines.contains { $0.1.contains("any StreamFactory") },
                          "\(name) 没有接在 StreamFactory 上 —— 两条流不再同构")
            XCTAssertTrue(lines.contains { $0.1.contains("makeStream(") },
                          "\(name) 没有造流 —— 这一屏/这条流永远不会开")
        }
    }

    /// 业务侧不持有传输层：重连整条连接的动作在屏幕与订阅方手里都不存在。
    ///
    /// 与 `testBothBusinessStreamsUseTheSameFactory` 是同一件事的两半：那一半守「怎么开」，
    /// 这一半守「不能动什么」。
    func testBusinessSidesHoldNoTransport() throws {
        let roots = ["Features", "Core/Gateway/Events"]
        var scanned = 0
        for root in roots {
            let files = swiftFiles(under: sourcesRoot.appendingPathComponent(root))
            XCTAssertFalse(files.isEmpty, "\(root) 一个文件都没扫到 —— 先怀疑路径推算")
            for file in files {
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (line, code) in codeLines(in: text) where code.contains("WebSocketConnection") {
                    XCTFail("\(root)/\(file.lastPathComponent):\(line) 出现了传输层 —— 业务只该拿造流口")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "只扫到 \(scanned) 个文件 —— 先怀疑路径推算")
    }

    /// 判活只有一个入口：心跳必须走 `livenessStep`，窗口必须从实例上读。
    ///
    /// 纯函数谁都能调 —— 在调用点写死一个窗口值不会让任何**行为**判据变红，但会让
    /// 「窗口可拨」变成空话：拨了不生效，测试照样绿。所以这里数两件事：调用点只有一处，
    /// 且那一处喂的是 `livenessWindow`。
    func testTheLivenessVerdictHasASingleCallSite() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/WebSocket/WebSocketConnection.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))
        let callSites = lines.filter { $0.1.contains("livenessTick(") && !$0.1.contains("func ") }

        XCTAssertEqual(callSites.count, 1, "livenessTick 被调用 \(callSites.count) 次（该恰好一次）")
        XCTAssertTrue(callSites.allSatisfy { $0.1.contains("window: livenessWindow") },
                      "唯一那次调用必须读实例上的窗口，不能写死")
    }

    /// 改造前/本期删掉的旧名在源码里零命中：改名与删接口都不留残影。
    ///
    /// 正控：`StreamMux` 必须命中 —— 否则说明扫描本身没工作（空集会被读成合规）。
    func testTheOldNamesAreGone() throws {
        let retired = [
            "FollowClient", "SessionStreamHandle", "Subscription", "sendAllOpens", "forgetAll",
            "ConnectionStore", "StreamTransport", "StreamPhase",
            "StreamBackoff", "GatewayLink", "GatewayClient", "GatewayClientError",
            "Gateway/Client",
            // 判活不再向流层要信息之后，这四个符号随接口一起消失。
            "didEstablish", "AbandonReason", "awaitingOpening", "hasPendingOpening",
            // 层界与命名那一期作废的名字：作用域词与「宿主」都不再说它是什么。
            "GatewayHost", "GatewayConnection", "ConnectionEventStream",
            "ConnectionEventReader", "ConnectionEventReading", "StreamPort",
        ]
        var hits: [String] = []
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for name in retired where code.contains(name) {
                    hits.append("\(file.lastPathComponent):\(line) \(name)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 40, "只扫到 \(scanned) 个文件 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [], "旧名还有残留：\(hits)")

        // 正控：造号点必须在，且它现在的名字是新的。
        let mux = try String(
            contentsOf: sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/Stream/StreamMux.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(mux.contains("static func newStreamId()"), "新造号点没扫到 —— 判据可能扫错了树")
    }

    /// 一条投递通道：无编号帧那条路整条没了，客户端收到的帧只有「进流表」一种去处。
    ///
    /// 正控：`LongConnection` 的 `makeStream` 必须命中 —— 否则说明扫描面取错了，
    /// 空集会被读成合规。
    func testTheSecondDeliveryPathIsGone() throws {
        var hits: [String] = []
        for file in swiftFiles(under: sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for name in ["UnscopedFrameSink", "UnscopedFrameFeed", "unscopedSink", "streamId == nil"]
                where code.contains(name) {
                    hits.append("\(file.lastPathComponent):\(line) \(name)")
                }
            }
        }
        XCTAssertEqual(hits, [], "无编号帧那条路的残留：\(hits)")

        let link = try String(
            contentsOf: sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/LongConnection.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(link.contains("func makeStream"), "造流入口没扫到 —— 判据可能扫错了树")
    }

    /// 两种新货物在判读器里**各有一支**（恰好一次）—— 只改类型不加分支时，审批到不了任何地方；
    /// 而两支变三支，说明有人在第二个地方又解释了一遍这个 kind。
    ///
    /// 正控：`"emit"` 必须命中，否则说明扫错了文件。
    ///
    /// 末尾那条守的是「认不出时留痕要带名字」：不带 `\(kind)` 的那行 warn 现场只剩
    /// 「丢了一条东西」，而版本错配时最要紧的正是**丢的是哪一种**。
    func testTheApprovalCargoesAreRead() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/Events/EventReader.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for kind in ["waterfall", "cancel", "emit"] {
            let hits = text.components(separatedBy: "\"\(kind)\"").count - 1
            XCTAssertEqual(hits, 1, "判读器里 \"\(kind)\" 该恰好出现一次，实际 \(hits) 次")
        }
        XCTAssertTrue(text.contains("does not know: \\(kind)"),
                      "认不出的 kind 没被写进日志 —— 版本错配时现场分不出丢的是什么")
    }

    /// 列表行的待审批标记撤干净了：类型、计数、渲染三样都不许留。
    ///
    /// 「这个会话有几条在等」不再是产品概念 —— 上游每个会话只有一条待交互投影，也没有计数。
    /// 留一个孤儿类型或一条没人读的计数，就是留一个「以后再接个消费者」的口子；接上之后
    /// 同一件事就有两处各说一遍。
    ///
    /// 正控：列表行的「进行中」必须还在 —— 否则说明扫描面取错了，空集会被读成合规。
    func testTheListRowMarkerIsGone() throws {
        let retired = ["SessionRowChip", "pendingCount"]
        var hits: [String] = []
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for name in retired where code.contains(name) {
                    hits.append("\(file.lastPathComponent):\(line) \(name)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 40, "只扫到 \(scanned) 个文件 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [], "列表标记还有残留：\(hits)")

        let listView = try String(
            contentsOf: sourcesRoot.appendingPathComponent("Features/SessionList/Views/SessionListView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(listView.contains("struct SessionRow"), "行的定义没扫到 —— 判据可能扫错了树")
    }

    /// 阶段类型提出去了：业务与视图读的是顶层 `ConnectionPhase`，没有谁还写 `FollowClient.Phase`。
    ///
    /// 断言按**文件名单**，不按出现次数：这个名字在四处出现（声明、连接层两个字段、门面的
    /// `phase`），数次数时那四处正好凑够阈值 —— 四屏消费点一个都没跟进也照样绿。
    func testThePhaseTypeIsTopLevelAndConsumed() throws {
        // 消费点名单：会话详情的编排与它那两个视图。哪里新增一处读阶段的地方，就加一个名字。
        let consumers = [
            "Features/SessionDetail/State/SessionSync.swift",
            "Features/SessionDetail/Views/ComposerStrip.swift",
            "Features/SessionDetail/Views/NetworkSheet.swift",
        ]
        for path in consumers {
            let file = sourcesRoot.appendingPathComponent(path)
            let text = try XCTUnwrap(try? String(contentsOf: file, encoding: .utf8),
                                     "\(path) 打不开 —— 名单要跟着挪文件改")
            XCTAssertTrue(codeLines(in: text).contains { $0.1.contains("ConnectionPhase") },
                          "\(path) 没读 ConnectionPhase —— 「提出去」只改了声明？")
        }
        // 旧宿主名不在这里守：`testTheOldNamesAreGone` 已扫 `ios/Sources`，重复只让报错更差。
    }

    /// 一条流的公开面没有连接级动作：「这条流坏了」与「整条连接断了」是两件事。
    ///
    /// 正控：`close` / `restart` 必须在（否则这段文本取错了，零命中是假绿）。
    func testLogicalStreamHasNoConnectionLevelActions() throws {
        let file = sourcesRoot.appendingPathComponent("Core/Gateway/LongConnection/Stream/StreamMux.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = codeLines(in: text)
        let body = try XCTUnwrap(block(startingAt: "final class LogicalStream", in: lines),
                                 "没找到 LogicalStream 的类型体 —— 先怀疑路径或改名")

        XCTAssertTrue(body.contains { $0.1.contains("func close()") }, "少了 close() —— 取错块了？")
        XCTAssertTrue(body.contains { $0.1.contains("func restart()") }, "少了 restart() —— 取错块了？")

        let forbidden = ["func reconnect", "func deactivate", "func abandon"]
        var hits: [String] = []
        for (number, code) in body {
            for word in forbidden where code.contains(word) {
                hits.append(":\(number) \(word)")
            }
        }
        XCTAssertEqual(hits, [], "一条流上出现了连接级动作：\(hits)")
    }

    /// 判读不需要连接 —— 判读器不引用连接层，也不碰网络。
    ///
    /// 这是「判读能脱离 socket 单独回答」在代码结构上的那一半：功能上它可以被单测调用，
    /// 结构上它一旦 import 了连接层或 `URLSession`，那种单测就会开始需要一条连接。
    ///
    /// 正控：文件里必须仍有 `func read(`，否则说明扫错了文件（空集读成合规）。
    func testReaderDoesNotDependOnConnection() throws {
        let file = sourcesRoot.appendingPathComponent("Features/SessionDetail/State/SessionStreamReader.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = codeLines(in: text)
        let forbidden = ["StreamMux", "WebSocketConnection", "URLSession", "MuxOpenFrame", "RpcClient"]

        XCTAssertTrue(lines.contains { $0.1.contains("static func read(") },
                      "没找到 `static func read(` —— 先怀疑路径或名字")

        var hits: [String] = []
        for (number, code) in lines {
            for word in forbidden where code.contains(word) {
                hits.append(":\(number) \(word)")
            }
        }
        XCTAssertEqual(hits, [], "判读器引用了连接层或网络类型：\(hits)")
    }

    /// `OpeningFrame` 的类型体不认识 `SessionPage` —— 线上形状不认识状态机的输入。
    ///
    /// 认的是**类型体**（`struct OpeningFrame {` 到它的右花括号），不是整个文件：同一个文件里
    /// `MuxOpenFrame` 的注释可以提到窗口。判据带正控：取到的类型体里必须有 `cursor`，
    /// 否则说明切块切错了位置，此时「零处 SessionPage」是假绿。
    ///
    /// 盲区：类型体里若声明同名嵌套结构，切块会提前结束（漏报方向）；这一条靠评审看。
    func testOpeningFrameDoesNotKnowSessionPage() throws {
        let text = try String(contentsOf: sourcesRoot.appendingPathComponent(
            "Core/Gateway/LongConnection/Wire/MuxFrames.swift"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0 == "struct OpeningFrame {" }) else {
            return XCTFail("没找到顶格的 `struct OpeningFrame {` —— 先怀疑名字或路径")
        }
        // 结束行取**顶格**的 `}`：嵌套类型与函数的右花括号都有缩进，按行首判才切得准。
        guard let end = lines[start...].firstIndex(where: { $0 == "}" }) else {
            return XCTFail("`struct OpeningFrame` 的类型体没有结束行 —— 先怀疑切块")
        }
        let body = lines[start...end]

        XCTAssertTrue(body.contains { $0.contains("let cursor: Int") },
                      "切出来的类型体里没有 `let cursor: Int` —— 切块位置错了，下面的零命中不算证据")
        for (offset, line) in body.enumerated() where contains("SessionPage", in: line) {
            XCTFail("Mux.swift:\(start + offset + 1) 的 OpeningFrame 类型体里出现 SessionPage"
                    + " —— 投影归 SessionPage 自己（init(opening:)），形状只交字段")
        }
    }

    /// `Display/` 不引用实现层的类型 —— 它要能被状态层与视图复用的前提。
    ///
    /// 唯一豁免是失败词汇 `RpcClientError`（一次请求怎么失败）：它是本层翻译的输入，
    /// 与 `GatewayErrorCode` 同性质，方向是呈现 → 通信、向下合法。
    func testDisplayDoesNotReferenceImplementationTypes() throws {
        let forbidden = try declaredTypes(under: gatewayImplementationDirectories, topLevelOnly: true)
            .filter { $0 != "RpcClientError" }
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

    /// `Features/*/State/` 下**含中文的行必须是注释行**（或以 `Log.` 开头）——
    /// 用户看得见的句子归各屏的 `Display/`，判定与编排只产出「哪一步 + 哪一类原因」。
    ///
    /// 判据形态照线上形状那几条：不认字符串字面量，改按行判。理由是**三引号多行串**——
    /// 单行引号正则对它 0 命中（复审复算过：往编排里写一段 `"""` 包着的中文，旧写法的
    /// 命中数不变）。而一段多行的用户文案正是最典型的写法之一，漏它等于没守。
    ///
    /// 两条豁免：
    /// - **注释行**（`//` / `///` / `*` / `/*` 开头）—— 注释本来就该是中文；
    /// - **整行以 `Log.` 开头** —— 日志文案在本项目一律写中文（`Core/Log.swift` 是唯一出口），
    ///   而日志不是用户看得见的面；把用户句子写进 `Log.` 里对用户没有意义。
    ///
    /// 白名单见 `stateStringExceptions`：每一条都要有理由，且过期会被
    /// `testStateStringExceptionsAreStillReal` 抓出来删掉。
    func testStateHasNoUserFacingStrings() throws {
        let interfaces = try interfaceDirectories()
        XCTAssertFalse(interfaces.isEmpty, "一个界面目录都没扫到：\(featuresRoot.path)")

        var commentLines = 0
        var hits = 0
        var scannedFiles = 0
        for interface in interfaces {
            for file in swiftFiles(under: interface.appendingPathComponent("State")) {
                if Self.stateStringExceptions[file.lastPathComponent] != nil { continue }
                scannedFiles += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (line, source) in allLines(in: text) where containsHan(source) {
                    let trimmed = source.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                        commentLines += 1
                        continue
                    }
                    if trimmed.hasPrefix("Log.") { continue }
                    hits += 1
                    XCTFail("\(interface.lastPathComponent)/State/\(file.lastPathComponent):\(line)"
                            + " 的中文不在注释里：\(trimmed) —— 用户可见的句子归 Display/")
                }
            }
        }
        XCTAssertGreaterThan(scannedFiles, 0, "一个 State 文件都没扫到 —— 先怀疑路径推算")
        XCTAssertEqual(hits, 0, "State/ 里还有用户可见的句子")
        XCTAssertGreaterThan(commentLines, 0, "State/ 里连中文注释都没有 —— 先怀疑路径或读取")
    }

    /// `State/` 下允许出现中文字面量的文件。**每一条都要有理由**，过期要删。
    ///
    /// 键是文件名，值是一句话理由 + 重开条件。白名单本身被下一条断言守着 ——
    /// 否则它会静默扩大豁免面（文件改名后旧条目失效、新文件悄悄多一个豁免）。
    private static let stateStringExceptions: [String: String] = [
        "TranscriptAssembler.swift": "过程行摘要（「3 次工具调用」「已思考」）随组装结果同处："
            + "它由同一批事件的计数拼出，不在别的屏复用，也没有独立的变化速率。"
            + "重开条件：下一次动过程行显示时，把它移到 `Display/`。",
    ]

    /// 白名单里的每一条都还真的需要 —— 文件没了、或里面已经没有中文字面量，就必须删掉这条。
    func testStateStringExceptionsAreStillReal() throws {
        for (fileName, reason) in Self.stateStringExceptions {
            var found: URL?
            for interface in try interfaceDirectories() {
                for file in swiftFiles(under: interface.appendingPathComponent("State"))
                where file.lastPathComponent == fileName {
                    found = file
                }
            }
            guard let file = found else {
                XCTFail("白名单里的 \(fileName) 已不在任何 State/ 下 —— 删掉这条例外（原写：\(reason)）")
                continue
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            var hasLiteral = false
            for (_, source) in allLines(in: text) where containsHan(source) {
                let trimmed = source.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                if trimmed.hasPrefix("Log.") { continue }
                hasLiteral = true
            }
            XCTAssertTrue(hasLiteral,
                          "\(fileName) 已经没有中文字面量了 —— 删掉这条例外（原写：\(reason)）")
        }
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
        let mirror = sourcesRoot.appendingPathComponent("Features/SessionDetail/State/SessionMirror.swift")
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
                    + " —— 用 SessionPage(opening:)")
        }
        XCTAssertEqual(copies, 0, "编排里还有三个字段的搬运")
    }

    // MARK: - 断言 16：界面 Views/ 不直接认识编排

    /// 界面 `Views/` 下除宿主之外不出现 `SessionSync` —— 视图只吃「已经算好的值」。
    ///
    /// 宿主 = `<界面名>View.swift`（`SessionDetailView` / `SessionListView` / `PairingView`）：
    /// 它是编排与渲染的唯一接线点，本来就该认识编排。别的视图若也认识，判定容易跟着取数
    /// 一起进到视图里。
    ///
    /// **扫整个界面目录，排除 `State/` 与 `Display/`**：只扫 `Views/` 时，视图放在界面目录
    /// 根部会被静默放行；而 `Display/` 的职责正是消费状态类型（把 `Status` 写成句子），
    /// 它认识 `SessionSync` 是对的。`State/` 本来就该放编排。
    ///
    /// **视图一个都不认识它**（连宿主也不认识：装配归容器）：正控因此落在 `State/` 上
    /// —— 那个类型确实还被这一屏用着，扫不到说明路径推算错了，零命中是假的。
    ///
    /// 盲区：把类型 `typealias` 成别的名字后认不出（漏报方向）；整行注释被跳过，
    /// **行内**注释里出现算命中（误报方向，接受）。
    func testViewsDoNotKnowOrchestrationTypes() throws {
        let interfaces = try interfaceDirectories()
        var scanned = 0
        var stateSides = 0

        for interface in interfaces {
            for file in swiftFiles(under: interface) {
                let text = try String(contentsOf: file, encoding: .utf8)
                if file.path.contains("/State/") {
                    if text.contains("SessionSync") { stateSides += 1 }
                    continue
                }
                guard !file.path.contains("/Display/") else { continue }
                scanned += 1
                for (line, code) in codeLines(in: text) where contains("SessionSync", in: code) {
                    XCTFail("\(interface.lastPathComponent)/\(file.lastPathComponent):\(line)"
                            + " 出现 SessionSync —— 视图只吃算好的值，判定归 State/")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 0, "一个非 State/ 的文件都没扫到 —— 先怀疑路径推算")
        XCTAssertGreaterThan(stateSides, 0, "没有任何 State/ 认识 SessionSync —— 先怀疑路径推算")
    }

    // MARK: - 待答表的三条结构判据

    /// 被删掉的那套补偿逻辑（配对、残骸过滤、悬空审计、已收口知识）的符号没有被粘回来。
    ///
    /// 它守的是**删除不被回退**，不是「配对以另一个名字复活」—— 后者抓不住，那正是
    /// `ApprovalTable` 的签名只收载荷、收不到事件流的意义。
    /// 只扫代码行（注释里解释「为什么不再需要它」是正当的）。活性锚用文件数 ——
    /// 路径推算错了时，下面的空集会被读成合规。
    func testTheDeletedApprovalSymbolsHaveNotComeBack() throws {
        let dead = ["ApprovalInbox", "standingCallIds", "settledCallIds",
                    "approvals.rebuild", "func pairs("]
        var hits: [String] = []
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for needle in dead where code.contains(needle) {
                    hits.append("\(file.lastPathComponent):\(line) \(needle)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "扫到的源码文件太少 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [], "补偿逻辑还在：\(hits)")
    }

    /// 待答表只有一个实例，且就建在根部 —— 它是 App 级的，多一个就有两张各说各话的表。
    func testThePendingTableIsBuiltOnceAtTheRoot() throws {
        var found: [String] = []
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) where code.contains("ApprovalStore(") {
                found.append("\(file.lastPathComponent):\(line)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "扫到的源码文件太少 —— 先怀疑路径推算")
        XCTAssertEqual(found.count, 1, "待答表只能有一个实例（App 级）：\(found)")
        XCTAssertEqual(found.first?.split(separator: ":").first, "DshMobileApp.swift",
                       "它该建在根部：\(found)")
    }

    /// 表不认识会话事件 —— 卡片只来自帧，不从日志算。
    func testThePendingTableDoesNotReadSessionEvents() throws {
        let file = sourcesRoot.appendingPathComponent("Features/Approval/State/ApprovalTable.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("struct ApprovalTable"), "扫错文件了")
        let hits = codeLines(in: text).filter { $0.1.contains("SessionEvent") }.map(\.0)
        XCTAssertEqual(hits, [], "表读了会话事件（第 \(hits) 行）—— 卡片只能来自帧")
    }

    // MARK: - 列表读事件的两条结构判据

    /// 每个屏的 state 只有一个实例。
    ///
    /// 两个实例的症状都是静默的：列表那份各持一行序，事件只喂到其中一个，另一份一直显示
    /// 旧内容；详情那份则会让同一次操作发两条流。
    ///
    /// 构造点住组合根（单例）与 `makeDetail`（每会话一份）——
    /// 判据只数次数，不钉文件 —— 钉文件会在构造点移动时假红一次，而「几处」才是它要守的东西。
    func testEachScreenStateIsBuiltOnce() throws {
        let names = ["SessionListState(", "SessionDetailState(",
                     "PairingState(", "MeshSetupState(", "SettingsState("]
        var found: [String: [String]] = [:]
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) {
                for name in names where Self.mentionsType(code, name) {
                    found[name, default: []].append("\(file.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "扫到的源码文件太少 —— 先怀疑路径推算")
        for name in names {
            let sites = found[name] ?? []
            XCTAssertEqual(sites.count, 1, "\(name) 只能构造一处：\(sites)")
        }
    }

    /// 渲染视图不认识**传输与持久化** —— 认识读模型是可以的，认识实现不行。
    ///
    /// 原先这条写的理由是「字段里没有服务类型，不是不许写是拿不到」。那句话是假的：
    /// `@Environment(MeshStore.self) private var store` 就是一个字段，写明了类型、也拿得到。
    /// 视图确实在读连接域的四个投影（`phase` / `meshPath` / `nodeState` / `storedConfigDamaged`），
    /// 那是设计，不是泄漏 —— 界线是「认识的是事实还是实现」。
    ///
    /// 所以这里只禁实现：拿到它们就等于知道「怎么发、怎么连、存哪儿」。依赖**几条通道**由
    /// `testRenderViewsTakeOneChannel` 守，两条各管一半。
    ///
    /// 盲区：类型名换了就认不出（漏报方向）；行内注释里出现算命中（误报方向，接受）。
    func testRenderViewsHoldNoServices() throws {
        let files = [
            "Features/SessionList/Views/SessionListView.swift",
            "Features/SessionDetail/Views/SessionDetailView.swift",
            "Features/Pairing/Views/PairingScreen.swift",
            "Features/MeshSettings/Views/MeshSettingsView.swift",
            "Features/Settings/Views/SettingsView.swift",
        ]
        let banned = ["RpcClient", "LongConnection", "EventStream"]
        var scanned = 0
        for path in files {
            let url = sourcesRoot.appendingPathComponent(path)
            let lines = codeLines(in: try String(contentsOf: url, encoding: .utf8))
            for (i, code) in lines {
                scanned += 1
                for name in banned where code.contains(name) {
                    XCTFail("\(path):\(i) 出现 \(name) —— 视图认识传输层就等于知道怎么发")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "扫到的行太少 —— 先怀疑路径推算")
    }

    /// 渲染视图的依赖只有一条通道：构造参数。
    ///
    /// 为什么只守通道、不数参数个数：个数是「显式」的代理指标。管个数就会为了凑数造转发层
    /// —— 一屏的依赖都是两三个显式参数时，硬包一个容器只为了让签名看起来是一个。
    /// 真正要守的是「没有第二条通道」：
    /// - 零 `@Environment(T.self)` —— `@Environment(\.scenePhase)` 这类平台值是系统给的，不在其列。
    ///
    /// 盲区：参数之间有没有重复、有没有一个参数其实用不上，这条看不见 —— 那要靠评审；
    /// 「容器自己是不是转发层」由 `testContainersEarnTheirKeep` 守，两条各管一半。
    func testRenderViewsTakeOneChannel() throws {
        let files = [
            "Features/SessionList/Views/SessionListView.swift",
            "Features/SessionDetail/Views/SessionDetailView.swift",
            "Features/Pairing/Views/PairingScreen.swift",
            "Features/MeshSettings/Views/MeshSettingsView.swift",
            "Features/Settings/Views/SettingsView.swift",
        ]
        var checked = 0
        for path in files {
            let url = sourcesRoot.appendingPathComponent(path)
            let lines = codeLines(in: try String(contentsOf: url, encoding: .utf8))
            for (i, code) in lines where code.contains("@Environment(") {
                guard code.contains("@Environment(\\.") else {
                    XCTFail("\(path):\(i) 从环境取对象 —— 依赖走构造参数，没有第二条通道")
                    continue
                }
            }
            checked += 1
        }
        XCTAssertEqual(checked, files.count, "有个文件没扫到 —— 先怀疑路径推算")
    }

    /// 容器要有决定权：至少一条对外成员做了**绑定**或**组合**。
    ///
    /// 转发不只有「字段转发」一种形状。`var phase { store.phase }` 与 `let phase = store.phase`
    /// 是同一件事，只是换了语法 —— 判据看成员做了什么，不看它写成了哪种形式。两种算做了事：
    /// - **绑定**：把屏内固定的输入填进去（`approvals.pending(in: session.id)` —— 视图不必
    ///   知道这一屏是哪个会话）；
    /// - **组合**：多个输入合成新值（`meshSummary` = 阶段 + 路径 + 文案）。
    ///
    /// 零条的容器没有任何决定权，它是转发层 —— 删掉它，依赖直接进签名。
    ///
    /// **闭集来自消费侧**：候选是「渲染视图签名里出现过的 `*State` 类型」。这样新增一个容器
    /// 必然先进某个视图的签名，才可能被当成依赖面 —— 点名单会让新长出来的转发层静默逃掉。
    ///
    /// 盲区（漏报方向）：只要求「至少一条」。一个容器四条成员里三条是读穿也能通过 ——「超过
    /// 一半是搬运就该并回」（`RULES` 结构 7）这半条没有判据，靠评审。要收紧的话，判据得数
    /// 成员总数并区分三类，而「读穿」在实现上难与「单值投影」分开（`sync.eventCount == 0`
    /// 做了变换但只读一处）。
    func testContainersEarnTheirKeep() throws {
        // 纯成员访问链：`{ store.phase }` / `{ a.b.c }` —— 什么都没多做。
        let passthrough = try NSRegularExpression(
            pattern: "^[[:space:]]*(?:var|let)[[:space:]]+[[:alnum:]_]+[[:space:]]*:"
                + "[^{]+\\{[[:space:]]*[[:alpha:]_][[:alnum:]_]*(?:\\.[[:alpha:]_][[:alnum:]_]*)*"
                + "[[:space:]]*\\}[[:space:]]*$")
        let typeName = try NSRegularExpression(pattern: "[A-Z][[:alnum:]_]*State\\b")

        // 消费侧：渲染视图签名里出现过的 State 类型名。
        let views = [
            "Features/SessionList/Views/SessionListView.swift",
            "Features/SessionDetail/Views/SessionDetailView.swift",
            "Features/Pairing/Views/PairingScreen.swift",
            "Features/MeshSettings/Views/MeshSettingsView.swift",
            "Features/Settings/Views/SettingsView.swift",
        ]
        var asked = Set<String>()
        for path in views {
            let url = sourcesRoot.appendingPathComponent(path)
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for m in typeName.matches(in: text, options: [], range: range) {
                guard let r = Range(m.range, in: text) else { continue }
                asked.insert(String(text[r]))
            }
        }
        XCTAssertGreaterThan(asked.count, 3, "视图签名里一个 State 都没扫到 —— 先怀疑路径推算")

        for name in asked.sorted() {
            // 定义它的那个文件 —— 只有带 `class` 的类型才是状态对象，值类型跳过。
            guard let file = swiftFiles(under: sourcesRoot).first(where: { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("class \(name)")
            }) else { continue }
            let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))
            // 方法本身算「绑定」：它把一次调用落到具体的动作上，不是纯读。
            let hasMethod = lines.contains {
                $0.1.trimmingCharacters(in: .whitespaces).hasPrefix("func ")
            }
            let hasDecidingMember = hasMethod || lines.contains { _, code in
                let range = NSRange(code.startIndex..<code.endIndex, in: code)
                guard code.contains("var "), code.contains("{"),
                      passthrough.firstMatch(in: code, options: [], range: range) == nil else {
                    return false
                }
                return true
            }
            XCTAssertTrue(hasDecidingMember,
                          "\(name)（\(file.lastPathComponent)）的成员全是转发 —— "
                          + "容器没有决定权，依赖该直接进签名")
        }
    }

    /// 列表永远是根 —— 前置条件不满足时不换屏。
    ///
    /// 这条守的是一类具体的伤害：正在读会话时隧道抖一下，整屏被换成组网页。旧设计那样做，
    /// 理由是「未就绪时只有一件事可做」，代价是把用户从正在做的事里弹走。
    ///
    /// 断法是**闭集计数**，不是禁写法。第一版数的是 `switch stage` / `case .needsMesh`
    /// 这几个字面量 —— 变异实测能绕过：把分支写成 `if case .ready = store.phase` 就全绿，
    /// 而伤害一模一样。禁写法守不住「换一种写法」，闭集才守得住。
    ///
    /// 全应用只有五处视图构造：根那一处（列表）+ 目的地注册那四处。多出第六处 ⇒ 有人在
    /// 根上按条件挑了另一屏。
    func testTheListIsAlwaysTheRoot() throws {
        let root = sourcesRoot.appendingPathComponent("DshMobileApp.swift")
        let lines = codeLines(in: try String(contentsOf: root, encoding: .utf8))

        // 正控：确认读到了那个栈与列表，否则下面的计数守的是空气。
        XCTAssertTrue(lines.contains { $0.1.contains("NavigationStack {") }, "没读到导航栈")
        XCTAssertTrue(lines.contains { $0.1.contains("SessionListView(list: list") },
                      "根不是列表 —— 首屏被别的面顶掉了")

        // 五处，各一次：根 + 四个目的地。
        let palette: [(name: String, expected: Int)] = [
            ("SessionListView(", 1),      // 根
            ("SessionDetailView(", 1),    // 目的地 .session
            ("SettingsView(", 1),         // 目的地 .settings
            ("MeshSettingsView(", 1),     // 目的地 .mesh
            ("PairingScreen(", 1),        // 目的地 .pairing
        ]
        for (name, expected) in palette {
            // 用左边界，不用裸 `contains`：`SettingsView(` 是 `MeshSettingsView(` 的后缀。
            // 第一版就是裸 contains，实测把 `SettingsView` 数成 3 次（多出的两条来自
            // `MeshSettingsView`），而那种假红会让人去改名字而不是改判据。
            let sites = lines.filter { Self.mentionsType($0.1, name) }.map { "\($0.0)" }
            XCTAssertEqual(sites.count, expected,
                           "\(name) 在组合根里出现 \(sites.count) 次（应 \(expected)）：\(sites)"
                           + " —— 多出来的那处是在根上按条件挑了另一屏")
        }
    }

    /// 两个配置页只能从目的地清单进入 —— 没有第二个入口。
    ///
    /// 守的是「配置动作只在设置页」。多一个入口的症状不是崩溃，是**两处行为各走各的**：
    /// 一处改了地址、另一处还按旧值显示。
    ///
    /// 断法：全仓 `MeshSettingsView(` 与 `PairingScreen(` 的构造点各恰好一处，且都在
    /// 组合根的目的地注册里。列表与设置只发 `Destination` 值，不构造它们。
    func testConfigScreensComeOnlyFromRoutes() throws {
        let expectations: [(type: String, allowedFile: String)] = [
            ("MeshSettingsView(", "DshMobileApp.swift"),
            ("PairingScreen(", "DshMobileApp.swift"),
        ]
        var scanned = 0
        for (type, allowed) in expectations {
            var sites: [String] = []
            for file in swiftFiles(under: sourcesRoot) {
                let relative = file.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
                let text = try String(contentsOf: file, encoding: .utf8)
                for (line, code) in codeLines(in: text) {
                    scanned += 1
                    // 只认**构造**：`MeshSettingsView(` 后面不是类型声明那一行。
                    guard code.contains(type), !code.contains("struct \(type.dropLast())") else {
                        continue
                    }
                    sites.append("\(relative):\(line)")
                }
            }
            XCTAssertEqual(sites.count, 1, "\(type) 的构造点应恰好一处（根部注册），实际：\(sites)")
            XCTAssertTrue(sites.first?.hasPrefix(allowed) == true,
                          "\(type) 的构造点不在组合根：\(sites)")
        }
        XCTAssertGreaterThan(scanned, 1000, "扫到的行太少 —— 先怀疑路径推算")
    }

    /// 列表不持有它读不到的依赖。
    ///
    /// 「转手」是这一期消掉的主要形状：字段原样传给下一屏，本屏一次都不读。它没有编译
    /// 错误、没有行为症状，只是把依赖面撑大，让「这一屏要什么」读不出来。
    ///
    /// 断法：每个字段名在**本文件**的其余位置必须至少出现一次（声明那一行不算）。
    func testSessionListHoldsNoUnusedDependency() throws {
        let path = "Features/SessionList/Views/SessionListView.swift"
        let file = sourcesRoot.appendingPathComponent(path)
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = codeLines(in: text)

        // 字段声明：`let name: Type`（视图的属性）。
        var fields: [(line: Int, name: String)] = []
        for (line, code) in lines {
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("let "), let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<colon])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("@") else { continue }
            fields.append((line, name))
        }
        XCTAssertGreaterThanOrEqual(fields.count, 3, "只扫到 \(fields.count) 个字段 —— 先怀疑推算")

        for field in fields {
            // 两边界都要：`\b` 会漏掉两种撞名，两种都实测命中过。
            // - `list` 命中 `SessionListState`（后缀）→ 要右边界
            // - `settings` 命中 `Destination.settings`（别的类型的成员）→ 要排除前置点号
            // 后者尤其阴：字段没被读过，但同名字的枚举成员让判据看起来绿。
            let name = NSRegularExpression.escapedPattern(for: field.name)
            let pattern = "(?<![.\\w])" + name + "(?![\\w])"
            let used = lines.contains { line, code in
                line != field.line
                    && code.range(of: pattern, options: .regularExpression) != nil
            }
            XCTAssertTrue(used, "\(path):\(field.line) 的 \(field.name) 从未被本屏读过 —— "
                          + "它在转手，该删掉")
        }
    }

    /// 组网配置在**任何前置条件下都可达** —— 「先配网、再配对」那条路的存在性。
    ///
    /// 为什么值得一条判据：组网页的入口只在设置里，而设置由列表的齿轮进入；列表永远在，
    /// 所以这条路永远通。缺了它，新装用户就永远配不上 —— 而这件事没有编译错误、没有行为
    /// 报错，只有真机上「配不上」一个症状。
    ///
    /// 锚落在两处 —— **清单**（`Destination.swift`）与**注册**（`DshMobileApp.swift`）。
    /// 两者是同一份契约的两半：只查清单，删掉注册那行仍然绿；只查注册，清单丢了那支
    /// 就没人发。
    ///
    /// 盲区：证不了注册真的匹配 `.mesh`（`switch` 分支那半靠评审）。
    func testMeshSettingsIsReachableWithoutIdentity() throws {
        let catalog = sourcesRoot.appendingPathComponent("Destination.swift")
        let catalogLines = codeLines(in: try String(contentsOf: catalog, encoding: .utf8))
        XCTAssertTrue(catalogLines.contains { $0.1.contains("case mesh") },
                      "目的地清单里没有组网 —— 组网没配好时无处可去")

        let root = sourcesRoot.appendingPathComponent("DshMobileApp.swift")
        let lines = codeLines(in: try String(contentsOf: root, encoding: .utf8))
        XCTAssertTrue(lines.contains { $0.1.contains("MeshSettingsView(setup: meshSetup, store: store)") },
                      "组网那一支不展示配置页 —— 「先配网、再配对」那条路断了")
    }

    /// 配对屏与组网设置是两个视图：一个换身份，一个换路径。
    ///
    /// 合在一起时，已配对状态打开组网设置会在标题「配对」的页面上挂着「输入 6 位配对码」——
    /// 而 `canPair` 不判是否已配对，按下去会真的再发一次配对请求。
    func testPairingAndMeshSettingsAreSeparate() throws {
        let pairing = sourcesRoot.appendingPathComponent("Features/Pairing/Views/PairingScreen.swift")
        let mesh = sourcesRoot.appendingPathComponent("Features/MeshSettings/Views/MeshSettingsView.swift")
        let pairingLines = codeLines(in: try String(contentsOf: pairing, encoding: .utf8))
        let meshLines = codeLines(in: try String(contentsOf: mesh, encoding: .utf8))
        XCTAssertTrue(pairingLines.contains { $0.1.contains("let state: PairingState") },
                      "扫错文件了 —— 配对屏不认识 PairingState？")
        XCTAssertTrue(meshLines.contains { $0.1.contains("@Bindable var setup: MeshSetupState") },
                      "扫错文件了 —— 组网设置不认识 MeshSetupState？")
        for (i, code) in pairingLines {
            for name in ["MeshSetupState", "MeshStore", "MeshConfig"] where code.contains(name) {
                XCTFail("PairingScreen.swift:\(i) 出现 \(name) —— 配对屏只管换身份")
            }
        }
        for (i, code) in meshLines {
            for name in ["PairingState"] where code.contains(name) {
                XCTFail("MeshSettingsView.swift:\(i) 出现 \(name) —— 组网页只管换路径")
            }
        }
    }

    /// 已配对那一支出现时要接上长连接 —— 「配对之后一切实时」的唯一入口。
    ///
    /// 它没有任何行为判据能碰到（视图不在测试覆盖里），而删掉它的症状是**配对成功后
    /// 列表页静默不更新、审批卡永不出现**：传输层把「无票」当终态（`activate` 的闸只让
    /// 第一次通过），不会自己再试。真正救场的只有「进一次会话详情」—— 所以这种缺口
    /// 会以间歇性报告的形式出现，极难归因。
    func testThePairedBranchStartsTheConnection() throws {
        let root = sourcesRoot.appendingPathComponent("DshMobileApp.swift")
        let lines = codeLines(in: try String(contentsOf: root, encoding: .utf8))
        // 触发点是「身份成立」，而身份只有 `CredentialStore` 一处。用 `.task(id:)` 钉住
        // 那个 id —— 写成无 id 的 `.task` 只在首帧跑一次，重新配对之后不会再来一次。
        XCTAssertTrue(lines.contains { $0.1.contains(".task(id: identity.hasDeviceToken)") },
                      "连接没有跟着身份走 —— 重新配对之后它不会再被拉起")
        XCTAssertTrue(lines.contains { $0.1.contains("guard identity.hasDeviceToken else") },
                      "没身份也去激活连接 —— 无票的连接会被传输层当终态收起")
        XCTAssertTrue(lines.contains { $0.1.contains("link.activate()") },
                      "onConnectionStart 成了空壳 —— 连接从未被激活")
        XCTAssertTrue(lines.contains { $0.1.contains("events.attach(to: link)") },
                      "连接活了但事件流没登记 —— 列表与审批都收不到")
    }

    /// 这一行是不是**提到了**那个类型 —— 要有左边界。
    ///
    /// 为什么不能直接 `contains`：`SettingsState(` 是 `MeshSettingsState(` 的后缀（后者后来
    /// 因零决定权被删，但这种从属命名还会再出现：`XxxScreenState` / `XxxSectionState`）。
    /// 用 `contains` 数出来的「两处构造」里会混进另一个类型，判据报出一个假的重复，然后有人
    /// 为了消除它去改名字 —— 那是治错了地方。
    private static func mentionsType(_ code: String, _ name: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: name)
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return re.firstMatch(in: code, options: [], range: range) != nil
    }

    /// 列表合并里的行拷贝只有一个入口。
    ///
    /// 逐字段重新构造时，「没提到的字段该保留」与「该换成新值」在字面上长得一样 ——
    /// 抄错任何一格都不编译失败，症状是「某个会话的进行中标记不见了」这类极难归因的小错。
    /// 收成一个 `copy(of:)` 之后，没被提到的字段不可能被抄错。
    func testTheListMergerCopiesRowsInOnePlace() throws {
        let file = sourcesRoot
            .appendingPathComponent("Features/SessionList/State/SessionListMerger.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))
        XCTAssertTrue(lines.contains { $0.1.contains("enum SessionListMerger") },
                      "扫错文件了 —— 先怀疑路径")
        let sites = lines.filter { $0.1.contains("SessionSummary(") }.map(\.0)
        XCTAssertEqual(sites.count, 1, "构造行的地方不止一处（第 \(sites) 行）—— 走 copy(of:)")
    }

    /// 视图不认识持久化类型 —— 配置的读与写都在状态层。
    ///
    /// 这条规则原先在配对屏破了：`@State` 的初值里 `MeshConfig.load()`（`@State` 初值每次
    /// 重建都求值，于是每重算一遍读两次盘），按钮闭包里 `save()`。视图因此既能读盘又能写盘，
    /// 而这两件事本该由状态层做完再把值给出来。
    func testViewsDoNotTouchPersistence() throws {
        var violations: [String] = []
        var scanned = 0
        let roots = [sourcesRoot.appendingPathComponent("Features"),
                     sourcesRoot.appendingPathComponent("SharedUI")]
        for root in roots {
            for file in swiftFiles(under: root) {
                guard file.path.contains("/Views/") || file.path.contains("/SharedUI/") else { continue }
                scanned += 1
                for (line, code) in codeLines(in: try String(contentsOf: file, encoding: .utf8))
                where code.contains("MeshConfig") {
                    violations.append("\(file.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 5, "扫到的视图文件太少 —— 先怀疑路径推算")
        XCTAssertEqual(violations, [], "视图碰了持久化类型：\(violations) —— 读与写都归 State/")
    }

    /// 容器只造不取数：`SessionDetailState` 里没有 `Task`、没有 `async` 成员。
    ///
    /// 不按 `await` 判：部件自己的取数闭包写在构造那一行里，那是部件的活 ——
    /// 把它算成容器的越界，判据会先假红一次。容器真要越界，长出来的必是
    /// `Task {` 或一个 `async` 方法。
    func testTheDetailContainerOnlyConstructs() throws {
        let file = sourcesRoot.appendingPathComponent("Features/SessionDetail/State/SessionDetailState.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))
        XCTAssertTrue(lines.contains { $0.1.contains("final class SessionDetailState") },
                      "扫错文件了 —— 先怀疑路径")
        let hits = lines.filter { $0.1.contains("Task") || $0.1.contains("async") }.map(\.0)
        XCTAssertEqual(hits, [], "容器里出现了取数或调度（第 \(hits) 行）—— 它只造不取数")
    }

    // MARK: - 待审批标记的三条结构判据

    /// 列表的取数不认识审批 —— 它不看审批的任何事实。
    ///
    /// 它的反面不是「多一个字段」，而是「列表为了显示审批又拉一次」：那是两张表各自
    /// 维护一份事实的开始。列表行上的待审批标记已撤掉（见 `testTheListRowMarkerIsGone`），
    /// 这条规则于是收得更紧：取数层连审批这个词都不该出现。
    func testTheListStateDoesNotKnowAboutApprovals() throws {
        let file = sourcesRoot.appendingPathComponent("Features/SessionList/State/SessionListState.swift")
        let lines = codeLines(in: try String(contentsOf: file, encoding: .utf8))
        XCTAssertTrue(lines.contains { $0.1.contains("final class SessionListState") },
                      "扫错文件了 —— 先怀疑路径")
        let hits = lines.filter { $0.1.lowercased().contains("approval") }.map(\.0)
        XCTAssertEqual(hits, [], "列表的取数层出现了审批（第 \(hits) 行）—— 列表不读审批的任何事实")
    }

    /// 从 `marker` 那一行起，取到下一个**顶格** `}`（含）为止。找不到 marker 返回 `nil`。
    ///
    /// 它截的是「文件里这一段文本」，不是「这个类型」：块内若出现一行以 `}` 起头的多行
    /// 字符串，块会提前截断。今天没有这种串；真加了多行串，判据要改成按大括号配平。
    /// 另一个边界更近：把内容抽成子视图之后，这段文本里就没有那一堆手势可查了 ——
    /// 那时判据要跟着扩到子视图的文件。
    private func block(startingAt marker: String,
                       in lines: [(Int, String)]) -> [(Int, String)]? {
        guard let start = lines.firstIndex(where: { $0.1.contains(marker) }) else { return nil }
        var out: [(Int, String)] = []
        for line in lines[start...] {
            out.append(line)
            if line.1.hasPrefix("}") { break }
        }
        return out
    }

    /// 列表状态真的被接上了事件流，而视图只剩「触发重拉」。
    ///
    /// 这一行是整条链路的入口，而它没有任何行为判据能碰到（视图不在测试覆盖里）：
    /// 删掉它，两端的判据全绿而列表永远不动。结构判据是唯一守得住它的形式。
    ///
    /// 锚落在**组合根**：它造这个 state，也就由它接。视图的字段里没有 `EventStream`，
    /// 所以锚不在视图 —— 那一半（服务不进渲染视图的字段）由
    /// `testRenderViewsHoldNoServices` 守，两条各守一半。
    func testTheListStateIsSubscribedToTheEventStream() throws {
        let root = sourcesRoot.appendingPathComponent("DshMobileApp.swift")
        let rootLines = codeLines(in: try String(contentsOf: root, encoding: .utf8))
        XCTAssertTrue(rootLines.contains { $0.1.contains("listState.attach(events: events)") },
                      "根没有把事件流交给列表状态 —— 事件到不了列表")

        let list = sourcesRoot.appendingPathComponent("Features/SessionList/Views/SessionListView.swift")
        let listLines = codeLines(in: try String(contentsOf: list, encoding: .utf8))
        XCTAssertTrue(listLines.contains { $0.1.contains("await list.reload()") },
                      "扫错文件了：连首载都不在这份文件里")
    }

    /// 上游的事件名与字段名不出网关。手机端只认 `SessionListChange` 的四支 ——
    /// 它若也认识 `api-session/added`，上游每改一次形状就要改两处。
    func testTheClientDoesNotKnowUpstreamEventNames() throws {
        var hits: [String] = []
        var scanned = 0
        for file in swiftFiles(under: sourcesRoot) {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, code) in codeLines(in: text) where code.contains("api-session/") {
                hits.append("\(file.lastPathComponent):\(line)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "扫到的源码文件太少 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [], "客户端出现了上游事件名：\(hits)")
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
    /// 收集实现层声明的类型名。
    ///
    /// 跳过各层下的 `Wire/`：那里面是两端契约形状（`OpeningFrame` 等），不是实现 ——
    /// 契约之间互相引用是允许的，把它们算进来会让根 `Wire/` 的合法引用变成违规。
    private func declaredTypes(under directories: [URL], topLevelOnly: Bool = false) throws -> [String] {
        var names: [String] = []
        for directory in directories {
            for file in swiftFiles(under: directory) {
                if file.path.contains("/Wire/") { continue }
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

    private func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}

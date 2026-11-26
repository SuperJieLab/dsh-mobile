/**
 * 源码层面的几条判据 —— 读的是仓库里的文件，不是被测对象的状态。
 *
 * 它们住在判据 target 而不是测试 target：这些断言要的前提是「仓库在这台机器上」，
 * 而手机上没有这个前提。凡是能写成「某个源文件里不许出现某段文本」的，都归这里。
 *
 * 一半是「显示层不许内置业务字面量」：内置了就等于把网关或宿主的清单抄了一份，
 * 而那两份漂移时没有任何东西会红。另一半是「丢弃要留痕」：一段被丢掉的输入如果不留痕，
 * 屏幕上的「什么都没发生」与「这条路断了」长得一模一样。
 */
import Foundation
import XCTest

final class SourceLevelTests: XCTestCase {

    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // judges/
            .deletingLastPathComponent() // ios/
    }

    private var repoRoot: URL {
        iosRoot.deletingLastPathComponent()
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 打开一屏只有一个来源

    /// `SessionFollowing` 里没有「等了几秒就改走 HTTP」的兜底。
    ///
    /// 失败形态是两条来源各自算一份水位（「我读到 12」与「我读到 13」同时存在，而两者都
    /// 不报错）。第 2 期起打开帧是唯一来源，兜底连同 `readSnapshot` 一起删了 —— 这条判据
    /// 守的是它别以别的名字长回来。
    ///
    /// **判据是「没有第二条取数路」这件事本身**，所以扫的是「取数」的标记：
    ///
    /// - 快照读、那个闭包、以及 `Timer` **全目录禁**（它们只服务兜底）；流开关上再禁
    ///   HTTP 客户端（`RpcClient` / `readPage`）。
    /// - `Task.sleep` 只放行**合并窗口**那一种：参数写成 `*WindowNanos`（`RefreshGate` 的
    ///   批窗口、草稿同帧合并、权限目录合并），它们不取数，只是把一个渲染帧内的多次变化
    ///   并成一次重算。兜底那种「等几秒」写的是裸纳秒数，照样被抓。
    ///
    /// `start()` 必须在（正控：切块没切错）。
    func testTheSecondScreenNeverComesOverHTTP() throws {
        let root = iosRoot.appendingPathComponent("Sources/Features/SessionDetail")
        let files = Self.swiftFiles(under: root).filter { $0.path.contains("/State/") }
        // 活性锚：目录扫空了下面的差集也会「通过」。
        XCTAssertGreaterThanOrEqual(files.count, 42, "只扫到 \(files.count) 个状态文件 —— 路径推算错了？")

        // 禁词分两档，因为「第二条取数路」在两个地方会长：
        //  ① 整个状态目录都不许出现 —— 快照读、那个闭包、`Timer`（它们只服务兜底）；
        //  ② 只有流开关不许出现 —— HTTP 客户端（`RpcClient` / `readPage`：翻页是读侧编排
        //     的事，流开关不该自己发请求）。
        // `Task.sleep` 单独判：只放行合并窗口（参数是 `*WindowNanos`），见下。
        let bannedEverywhere = ["readSnapshot", "syncNow", "Timer"]
        let bannedInFollowing = ["RpcClient", "readPage"]
        let windowSleep = "WindowNanos"

        var hits: [String] = []
        for file in files {
            let name = file.lastPathComponent
            let text = try read(file)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(line)
                for banned in bannedEverywhere where code.contains(banned) {
                    hits.append("\(name):\(number + 1) \(banned)")
                }
                // 定时器只放行合并窗口：裸纳秒数的 sleep 就是「等几秒」的兜底形态。
                if code.contains("Task.sleep") && !code.contains(windowSleep) {
                    hits.append("\(name):\(number + 1) Task.sleep 不是合并窗口")
                }
                if name == "SessionFollowing.swift" {
                    for banned in bannedInFollowing where code.contains(banned) {
                        hits.append("\(name):\(number + 1) \(banned)")
                    }
                }
            }
        }
        let following = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionFollowing.swift"))
        XCTAssertTrue(following.contains("func start()"), "读到的不是流开关 —— 先怀疑路径推算")
        XCTAssertEqual(hits, [],
                       "状态层里又出现了第二条取数路 —— 一屏只有一个来源")
    }

    // MARK: - 收帧链路只解一次

    /// 收帧链路上 `JSONDecoder(` 只出现在形状层，且只有一处。
    ///
    /// 守的是「同一份线上文本被解析两次」。**扫的是目录不是清单** —— 写死一份文件列表时，
    /// 往后在 `LongConnection/` 下新增一个文件（拆类型、加一层）默认就是绿的，判据形同虚设。
    /// 目录扫空了也不行（路径改名会让它一个文件都看不到，那等于什么都没测），所以先断言条数。
    func testTheInboundPathDecodesExactlyOnce() throws {
        let root = iosRoot.appendingPathComponent("Sources/Core/Gateway/LongConnection")
        let files = Self.swiftFiles(under: root)
        XCTAssertGreaterThan(files.count, 10, "扫到的文件太少，路径可能变了")

        var hits: [String: Int] = [:]
        for file in files {
            let relative = file.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
            let count = Self.codeLineCount(of: "JSONDecoder(", in: try read(file))
            if count > 0 { hits[relative] = count }
        }
        XCTAssertEqual(hits, ["Sources/Core/Gateway/LongConnection/Wire/MuxFrames.swift": 1],
                       "收帧链路上应只在形状层解一次，实际：\(hits)")

        // 判读层：进到这里的已经是解好的值，再解一次就是把成本原样加回来。
        for relative in ["Sources/Features/SessionDetail/Sync/State/SessionBehavior.swift",
                         "Sources/Features/SessionDetail/Sync/State/SessionStreamReader.swift",
                         "Sources/Core/Gateway/LongConnection/Stream/EventsStream.swift",
                         "Sources/Core/Gateway/LongConnection/Stream/ControlStream.swift"] {
            let count = Self.codeLineCount(
                of: "JSONDecoder(", in: try read(iosRoot.appendingPathComponent(relative))
            )
            XCTAssertEqual(count, 0, "\(relative)：判读层又自己解了一次字节")
        }
    }

    /// 数 `needle` 在**代码**里出现的次数。
    ///
    /// 三件事：跳过整行注释（判据本身就在若干条注释里写着这个符号）；削掉行尾注释
    /// （`let x = 1 // JSONDecoder(` 不该算实现）；按出现次数计而不是按行计
    /// （一行写两次只算一次，等于给了个绕过口）。
    ///
    /// 已知毛刺：字符串里含 `//` 的行会被提前截断。同一行既有 URL 又有解码调用的概率极低，
    /// 这里不为它加引号状态机。
    private static func codeLineCount(of needle: String, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: 0) { count, line in
            let head = line.range(of: "//").map { line[..<$0.lowerBound] } ?? line
            let trimmed = head.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/*"), !trimmed.hasPrefix("*") else { return }
            count += String(head).components(separatedBy: needle).count - 1
        }
    }

    // MARK: - 显示层不许内置档名 / 命令名

    /// 这两个名字最可能被写成映射表的地方是显示层 —— 但它也可能被写进同屏的任何一处，
    /// 所以**扫整个界面目录**，不点名文件。点名清单的失败方式是「新增一个文件默认合规」，
    /// 与上面那条「扫目录不扫清单」的纪律相反。
    private var sessionDetailRoot: URL {
        iosRoot.appendingPathComponent("Sources/Features/SessionDetail")
    }

    /// 快照的可见节点与消息条数必须是存储值。
    ///
    /// 做成计算属性就是每读一次全量过滤一遍，而视图 body 每帧读三次 —— 代价看不见，
    /// 只有长会话里叠出来。这条判据认**名字与形态**：两个读口都得是那两行 `let`。
    ///
    /// 只写「不许出现 `var visible: [ChatNode] {`」是抓不住它的 —— 那是已经删掉的旧名字，
    /// 把 `visibleNodes` 改回计算属性时一个字都不命中。所以正面要求 `let` 在场，
    /// 反面按现在的名字禁 `var`。
    func testSnapshotKeepsItsVisibleHalfStored() throws {
        let file = iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Transcript/State/Conversation/ChatNode.swift")
        let code = try read(file)
        XCTAssertTrue(code.contains("struct ChatSnapshot"), "判据的落点没找对：\(file.path)")

        let stored = ["let visibleNodes: [ChatNode]", "let messageCount: Int"]
        for needle in stored {
            XCTAssertTrue(code.contains(needle),
                          "\(file.lastPathComponent) 少了存储读口「\(needle)」—— 它必须是存储值")
        }

        let forbidden = ["var visibleNodes", "var messageCount"]
        for (line, text) in Self.codeLines(in: code) {
            for computed in forbidden {
                XCTAssertFalse(text.contains(computed),
                               "\(file.lastPathComponent):\(line) \(computed) 又把读口变回计算属性了 —— 每帧全量过滤 / 遍历")
            }
        }
    }

    /// 位置回填时的事件序不能每次从字典排一遍。
    ///
    /// 排序器与 `inputs` 是同一集合的两种视图，前插走的是「有序合并」而不是「排一次字典」。
    /// 判据只守这一个函数体：`rebuild` 自己的 `events.sorted` 是整段重建时跑一次的，不在守备面内。
    func testLocationRefreshDoesNotSortTheDictionary() throws {
        let file = iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Transcript/State/Conversation/ConversationAssembler.swift")
        let code = try read(file)
        guard let start = code.range(of: "private mutating func rebuildLocations()") else {
            return XCTFail("判据的落点没找对：`rebuildLocations` 不见了 —— \(file.lastPathComponent)")
        }
        let rest = code[start.upperBound...]
        let end = rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])
        XCTAssertGreaterThan(body.count, 100, "函数体取空了 —— 先怀疑落点")

        for (offset, line) in body.components(separatedBy: "\n").enumerated() {
            XCTAssertFalse(line.contains("values.sorted"),
                           "\(file.lastPathComponent) 的 rebuildLocations 第 \(offset + 1) 行又排了一次字典 —— 前插的代价会随 N log N 长")
        }
    }

    /// 作废 `held` 的两处都必须走「排回队列再清空」，整段重建那一处只清。
    ///
    /// `takeFeed` 取走即清，扣下的那一批已经消费过 —— 少了排回，被作废的记录就永久停在
    /// 镜像里没人再看一眼，症状是「那一轮少了一段」且没有任何报错。
    ///
    /// 数的是**协调者**的调用点（作废与清场的决定在它手里），排序与排回在输入单元内部，
    /// 由 `SessionInputTests` 的 `drainHeld` 用例守。
    func testDiscardingHeldEventsRequeuesThem() throws {
        // 作废点在投影（帧的消化里），清场点在协调者（整段重建那七步里）—— 两处各读各的文件。
        let projection = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionProjection.swift"))
        let drains = Self.codeLineCount(of: "input.drainHeld()", in: projection)
        XCTAssertEqual(drains, 2,
                       "两处作废点（新流开始、放弃的一轮）都要排回，实际只有 \(drains) 处")
        let sync = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let clears = Self.codeLineCount(of: "input.clearHeld()", in: sync)
        XCTAssertEqual(clears, 1,
                       "整段重建那一处只清不排回（镜像一起清空，排回无处可去），实际 \(clears) 处")
    }

    /// 消息行不参与父容器求解，交互层也不逐行挂。
    ///
    /// 两件事都是「每行各解一次」的来源：`.frame(maxWidth: .infinity…)` 让每行去解一次父宽，
    /// `.textSelection` 给每行挂一层交互。改法是把对齐交给 `HStack` + `Spacer`、
    /// 选择收到 `List` 一处 —— 判据守的是「这两样都不在消息行上」。
    func testMessageRowCarriesNoPerRowLayoutOrSelection() throws {
        let file = iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Root/Views/SessionDetailView.swift")
        let code = try read(file)
        guard let start = code.range(of: "private struct MessageBubble: View {") else {
            return XCTFail("判据的落点没找对：MessageBubble 不见了 —— \(file.lastPathComponent)")
        }
        let rest = code[start.lowerBound...]
        let end = rest.dropFirst().range(of: "\n}\n")?.upperBound ?? rest.endIndex
        let body = String(rest[..<end])
        XCTAssertGreaterThan(body.count, 200, "函数体取空了 —— 先怀疑落点")

        XCTAssertFalse(body.contains(".frame(maxWidth: .infinity"),
                       "消息行又在解一次父宽 —— 宽度交给 List 的行容器")
        XCTAssertFalse(body.contains(".textSelection("),
                       "选择交互又挂在每一行上了 —— 它该在 List 一处")

        // 不只数次数：位置也要在 `List` 的修饰链里，挪到别的容器上凑数要能红。
        let lines = code.components(separatedBy: "\n")
        let marks = lines.enumerated().filter { $0.element.contains(".textSelection(") }.map(\.offset)
        XCTAssertEqual(marks.count, 1, "整屏该恰有一处选择挂载")
        if let list = lines.firstIndex(where: { $0.contains(".listStyle(.plain)") }), let only = marks.first {
            XCTAssertTrue(only > list && only < list + 8,
                          "选择挂载不在 List 的修饰链上（第 \(only + 1) 行，List 在第 \(list + 1) 行）")
        }
    }

    /// 纯行视图的文件里不该有逐行的选择挂载。
    ///
    /// `TurnProcessRow` 展开后一屏几十条（思考、工具调用、中间文本），逐条挂一层交互的代价
    /// 比消息行更集中 —— 消息行一轮只有一条。`CommandRow` 本来就没有，一并钉住防回流。
    ///
    /// **只守选择，不守 `.frame`**：见下面那段注释。
    /// 还在生成的那一条不进排版缓存，定稿之后才进。
    ///
    /// 两条断言各挡一种写法。实参写成字面量时：`true` 让流式中间态灌满缓存（一段长回答的
    /// 帧数就是写入条数，240 个槽位换一遍，回来的全是再不会被读的文本）；`false` 让每条
    /// 定稿消息每次重建都重解析。不写实参同样落进 `true`（参数的默认值）。
    /// 第二条挡「为了让第一条绿而一刀切不缓存」—— 判据要求的是跟着节点状态走。
    func testTheMessageRowCachesMarkdownOnlyWhenSettled() throws {
        let views = iosRoot.appendingPathComponent("Sources/Features/SessionDetail/Root/Views")
        let code = try read(views.appendingPathComponent("SessionDetailView.swift"))
        guard let line = Self.codeLines(in: code)
            .first(where: { $0.1.contains("MarkdownText(source: message.text") }) else {
            return XCTFail("判据的落点没找对：消息行不再调 MarkdownText")
        }
        XCTAssertTrue(line.1.contains("caching:"),
                      "消息行没有交代 caching —— 默认值就是「一直在跑的消息也进缓存」")
        XCTAssertFalse(line.1.contains("caching: true"), "字面量 true：流式中间态会灌满缓存")
        XCTAssertFalse(line.1.contains("caching: false"), "字面量 false：定稿消息每次重建都要重解析")

        XCTAssertTrue(code.contains("isRunning: assistant.status == .running"),
                      "构造 DisplayMessage 时没带节点状态 —— caching 就无从取「在不在跑」")
    }

    func testRowViewFilesCarryNoPerRowSelection() throws {
        // 只守「选择」这一半，`.frame(maxWidth: .infinity)` 不扫。
        //
        // 理由：那个修饰符在源码里分不出两种用途 —— 为对齐（可用 `Spacer` 替，S8 要消的）
        // 与为撑满（卡片背景铺满、配合 `contentShape` 扩大点击区，删了就是行为变化）。
        // `ToolRowView` 的 `DetailBlock` 与 `TurnProcessRow` 的 `ThinkingRow` 都是后者。
        // 强行扫会让判据要么误报、要么逼着人为了绿而删必需的对齐。
        // 三件分属两个块：行渲染件在「Transcript」，命令行在「Composer」。
        let rows = [
            "Sources/Features/SessionDetail/Transcript/Views/TurnProcessRow.swift",
            "Sources/Features/SessionDetail/Transcript/Views/ToolRowView.swift",
            "Sources/Features/SessionDetail/Composer/Views/CommandRow.swift",
        ]
        for relative in rows {
            let name = (relative as NSString).lastPathComponent
            let code = try read(iosRoot.appendingPathComponent(relative))
            XCTAssertGreaterThan(code.count, 500, "\(name) 读空了 —— 先怀疑路径")
            for (line, text) in Self.codeLines(in: code) {
                XCTAssertFalse(text.contains(".textSelection("),
                               "\(name):\(line) 逐行挂选择层 —— 它该在 List 一处")
            }
        }
    }

    /// 缓存必须真的被播种 —— 这是「装配那一步」的判据。
    ///
    /// 删掉 `SessionDetailView` 里那一行 `.environment(...)`，编译通过（环境键有默认值）、
    /// 缓存自己的用例全绿、别的源码判据全绿 —— 全仓没有任何信号，而命中率归零。
    /// `RULES` 把这种形态叫「判据都落在组件边界上，漏了装配那一步」。
    func testTheMarkdownCacheIsActuallyPlanted() throws {
        let views = iosRoot.appendingPathComponent("Sources/Features/SessionDetail/Root/Views")
        let view = try read(views.appendingPathComponent("SessionDetailView.swift"))
        XCTAssertTrue(view.contains(".environment(\\.markdownCache, detail.markdownCache)"),
                      "播种那一行不见了 —— 视图会落到容量零的默认缓存，命中率归零且没有任何信号")

        let state = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Root/State/SessionDetailState.swift"))
        XCTAssertTrue(state.contains("let markdownCache = SessionMarkdownCache()"),
                      "状态里没有缓存实例 —— 播种拿不到东西")

        let text = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Transcript/Views/MarkdownText.swift"))
        XCTAssertFalse(text.contains("cache: SessionMarkdownCache? = nil"),
                       "cache 又变成可选了 —— 新调用点会悄悄不传，落到容量零的默认值")
        XCTAssertFalse(text.contains("cache: SessionMarkdownCache ="),
                       "cache 又有默认值了 —— 同上")
        XCTAssertTrue(text.contains("@Entry var markdownCache = SessionMarkdownCache.unplanted"),
                      "默认值改回 `SessionMarkdownCache()` 就会每次求值新建一份空缓存")
    }

    /// 常态喂食不读整份镜像 —— 全量过滤只剩 `durableEvents()` 一处。
    ///
    /// `feedEngine` 原来对 `mirror.events` 做两次全量 `filter`（去 `held`、去已在引擎里的）
    /// 来反推「哪些是新的」。改成由写入方交出一批之后，全量只剩两条稀有路径用得上
    /// （空引擎、窗口接不上）。判据认的是**位置**而不是次数：有几处全量过滤不是重点，
    /// 重点是常态路径不经过它 —— 所以那一处必须落在 `durableEvents()` 的函数体里。
    func testTheDurableFilterOnlyServesTheRareRebuildPaths() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionProjection.swift"))
        let hits = Self.codeLines(in: code).filter { $0.1.contains("input.records.filter") }
        XCTAssertEqual(hits.count, 1,
                       "`input.records.filter` 出现了 \(hits.count) 处 —— 全量反推又回来了")

        guard let start = code.range(of: "private func durableEvents()") else {
            return XCTFail("`durableEvents()` 不见了 —— 判据的落点没找对")
        }
        let body = String(code[start.lowerBound...].prefix(200))
        XCTAssertTrue(body.contains("input.records.filter"),
                      "那一处全量过滤不在 `durableEvents()` 里 —— 常态路径会经过它")
    }

    /// 输入侧的三个类型只由 `SessionInput` 持有。
    ///
    /// 编排层一旦自己还留一份，改它们的接口就要跟两处，而「哪一份是真的」编译期与运行时
    /// 都看不出来 —— 两份都在推进时表现为偶发的少行。
    ///
    /// 扫两遍：编排层一次（这一层最容易被顺手加回来），整个 `Sources` 一次（引回视图或新开
    /// 一个文件同样会造出第二份，而那两处不会被第一遍看见）。
    func testTheInputSideTypesLiveOnlyInTheInputUnit() throws {
        let names = ["SessionMirror", "TransientChannel", "SessionFollowing"]

        // 正控：确认扫到的是本体，不是被路径推算带偏的空文件。
        let sync = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let lines = Self.codeLines(in: sync)
        XCTAssertGreaterThan(lines.count, 120, "只扫到 \(lines.count) 行 —— 先怀疑路径")

        let hits = lines.filter { line in names.contains { line.1.contains($0) } }.map(\.0)
        XCTAssertEqual(hits, [], "编排层还点着输入侧的类型名：行 \(hits)")

        // 全仓：这三个名字只许出现在它们自己的定义处与输入单元里。
        let holders: Set<String> = ["SessionMirror.swift", "TransientChannel.swift",
                                    "SessionFollowing.swift", "SessionInput.swift"]
        let files = Self.swiftFiles(under: iosRoot.appendingPathComponent("Sources"))
        XCTAssertGreaterThan(files.count, 50, "只扫到 \(files.count) 个文件 —— 先怀疑路径")
        var strays: [String] = []
        for file in files where !holders.contains(file.lastPathComponent) {
            for (line, text) in Self.codeLines(in: try read(file))
            where names.contains(where: text.contains) {
                strays.append("\(file.lastPathComponent):\(line)")
            }
        }
        XCTAssertEqual(strays, [], "输入侧的类型名出现在不该点名的地方：\(strays)")

        // 另一半：那三样真的有个持有者，否则上面两条可以靠「谁都不持有」变绿。
        let input = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionInput.swift"))
        let inputLines = Self.codeLines(in: input)
        XCTAssertTrue(inputLines.contains { $0.1.contains("var window = SessionMirror()") },
                      "输入单元自己没有持有镜像 —— 上面那条是空守")
        XCTAssertTrue(inputLines.contains { $0.1.contains("var transient = TransientChannel()") },
                      "输入单元自己没有持有草稿通道 —— 上面那条是空守")
        XCTAssertTrue(inputLines.contains { $0.1.contains("= SessionFollowing ") },
                      "输入单元自己没有持有流开关 —— 上面那条是空守")
    }

    /// 输入单元只拿输入侧的东西，装配点把三处接线接上。
    ///
    /// 两半守的是同一件事的两面：拿多了（顺手把投影的状态也管起来）与接漏了
    /// （`makeStream` / `phase` 漏接都是**静默**的 —— 前者开流什么也不发生、后者恒 `.idle`，
    /// 而监听表条数与界面都照常）。
    func testTheInputUnitHoldsNoProjectionStateAndIsWired() throws {
        let input = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionInput.swift"))
        let inputLines = Self.codeLines(in: input)
        XCTAssertGreaterThan(inputLines.count, 50, "读空了 —— 先怀疑路径")
        let projectionTypes = ["ChatSnapshot", "ChatSnapshotBuilder", "ConversationAssembler"]
        let intruders = inputLines.filter { line in
            projectionTypes.contains { line.1.contains($0) }
        }.map(\.0)
        XCTAssertEqual(intruders, [], "输入单元拿了投影的状态：行 \(intruders)")

        let sync = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let syncLines = Self.codeLines(in: sync)

        // 三处接线各只许一处，且必须落在 `init` 的体里 —— 挪进 `startFollowing()` 是
        // 最像「也没写错」的失效方式：先开流后接工厂，这一屏就永远没有流。
        guard let initAt = syncLines.firstIndex(where: { $0.1.contains("init(client: RpcClient") }),
              let endAt = syncLines[initAt...].firstIndex(where: { $0.1.contains("func deliver(") })
        else { return XCTFail("没找到 `init` 的边界 —— 判据的落点不对") }
        // 比的是**行号**不是数组下标：`codeLines` 滤掉了注释行，两者不相等。
        let initLine = syncLines[initAt].0
        let endLine = syncLines[endAt].0
        for wire in ["input.makeStream = ", "input.connectionPhase = ", "input.onControlValues = "] {
            let wired = syncLines.filter { $0.1.contains(wire) }.map(\.0)
            XCTAssertEqual(wired.count, 1, "`\(wire)` 该只在装配点接一处，实际 \(wired.count) 处")
            guard let only = wired.first else { continue }
            XCTAssertTrue(only > initLine && only < endLine,
                          "`\(wire)` 不在 `init` 里（第 \(only) 行，init 在 \(initLine)…\(endLine)）"
                            + " —— 开流时它还没接上")
        }
        XCTAssertTrue(syncLines.contains { $0.1.contains("input.phase") },
                      "`phase` 不是转发 —— 漏接就恒 `.idle`，功能条永远停在未连接")
    }

    /// 引擎与它的三件附属只由投影持有。
    ///
    /// 编排层一旦还留一份，改「帧到达之后怎么更新快照」就要跟两处，而「哪一份是真的」
    /// 编译期与运行时都看不出来 —— 两份都在推进时表现为偶发的少行。
    func testTheEngineLivesOnlyInTheProjection() throws {
        let names = ["ConversationAssembler", "ChatSnapshotBuilder", "AssemblyChange", "RefreshGate"]
        let sync = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let syncLines = Self.codeLines(in: sync)
        XCTAssertGreaterThan(syncLines.count, 120, "只扫到 \(syncLines.count) 行 —— 先怀疑路径")
        let hits = syncLines.filter { line in names.contains { line.1.contains($0) } }.map(\.0)
        XCTAssertEqual(hits, [], "编排层还点着引擎与它的附属：行 \(hits)")

        let projection = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionProjection.swift"))
        let lines = Self.codeLines(in: projection)
        for name in names {
            XCTAssertTrue(lines.contains { $0.1.contains(name) },
                          "投影里没有 \(name) —— 上面那条是空守")
        }
    }

    /// 投影不持连接、不做翻页、不持分页读数。
    func testTheProjectionHoldsNoConnectionOrPaging() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionProjection.swift"))
        let lines = Self.codeLines(in: code)
        XCTAssertGreaterThan(lines.count, 150, "只扫到 \(lines.count) 行 —— 先怀疑路径")
        let forbidden = ["RpcClient", "readPage", "beginRequest", "LongConnection",
                         "ControlStream", "updateListeners", "hasMore"]
        var hits: [String] = []
        for (line, text) in lines {
            for word in forbidden where text.contains(word) {
                // `RpcClientError` 是错误模型里的一个值，不是那个客户端 —— 拒帧要用它包一层。
                if word == "RpcClient", text.contains("RpcClientError") { continue }
                hits.append("\(line):\(word)")
            }
        }
        XCTAssertEqual(hits, [], "投影拿了不属于它的东西：\(hits)")
    }

    /// 快照是转发：视图读的那个面还在协调者上，只是从投影取。
    func testTheSnapshotIsForwardedFromTheProjection() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        XCTAssertTrue(Self.codeLines(in: code).contains {
            $0.1.contains("var snapshot: ChatSnapshot") && $0.1.contains("projection.snapshot")
        }, "快照不是转发 —— 要么编排层又存了一份，要么读口变了形状")
    }

    /// 接线各一处、都在 `init` 的体里。
    ///
    func testTheProjectionIsWiredAtTheAssemblyPoint() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let lines = Self.codeLines(in: code)
        guard let initAt = lines.firstIndex(where: { $0.1.contains("init(client: RpcClient") }),
              let endAt = lines[initAt...].firstIndex(where: { $0.1.contains("func deliver(") })
        else { return XCTFail("没找到 `init` 的边界 —— 判据的落点不对") }
        // 比的是**行号**不是数组下标：`codeLines` 滤掉了注释行，两者不相等。
        let initLine = lines[initAt].0
        let endLine = lines[endAt].0
        // 九条都在名单里：`onLiveEventType` 也带 `projection.` 前缀，与协调者自己那个对外属性
        // （`SessionDetailState` 里另有一处赋值）分得开。
        let wires = ["projection.onSnapshotPublished = ", "projection.onRefreshNeeded = ",
                     "projection.onDurableRecords = ", "projection.onClaimedRow = ",
                     "projection.onVerdict = ", "projection.onRebuildNeeded = ",
                     "projection.onOpeningProjections = ", "projection.onLiveEventType = ",
                     "projection.onDataFrame = "]
        for wire in wires {
            let wired = lines.filter { $0.1.contains(wire) }.map(\.0)
            XCTAssertEqual(wired.count, 1, "`\(wire)` 该恰好一处，实际 \(wired.count) 处")
            guard let only = wired.first else { continue }
            XCTAssertTrue(only > initLine && only < endLine,
                          "`\(wire)` 不在 `init` 里（第 \(only) 行，init 在 \(initLine)…\(endLine)）")
        }
    }

    /// 读数与翻页只由 `SessionReadings` 持有。
    ///
    /// 编排层一旦还留一份，「还能往前翻吗」「顶部在等」就有两个真源：两份都在推进时表现为
    /// 偶发的按钮不消失、指示灯不熄，而编译期与运行时都看不出来。
    func testTheReadingsLiveOnlyInTheReadingsUnit() throws {
        let sync = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let lines = Self.codeLines(in: sync)
        XCTAssertGreaterThan(lines.count, 100, "只扫到 \(lines.count) 行 —— 先怀疑路径")

        let names = ["ResyncNoticeState", "UsageState", "readPage", "beginRequest",
                     "abandonRequest", "syncInFlight"]
        let hits = lines.filter { line in names.contains { line.1.contains($0) } }.map(\.0)
        XCTAssertEqual(hits, [], "编排层还点着读数侧的名字：行 \(hits)")

        // 另一半：那六样真的有个持有者，否则上面那条可以靠「谁都不持有」变绿。
        let unit = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionReadings.swift"))
        let unitLines = Self.codeLines(in: unit)
        for name in names {
            XCTAssertTrue(unitLines.contains { $0.1.contains(name) },
                          "读数单元里没有 \(name) —— 上面那条是空守")
        }
    }

    /// 六个读口是转发，不是又存了一份。
    ///
    /// 两份都在推进时表现为「切屏那一帧条数不对」，而下一次刷新又自己好了 —— 没有判据就
    /// 永远只能看到偶发。
    func testTheSixReadingsAreForwardedFromTheUnit() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let lines = Self.codeLines(in: code)
        for name in ["eventCount", "hasMore", "isPagingOlder", "notice", "usage", "lastFrameAt"] {
            XCTAssertTrue(lines.contains { $0.1.contains("{ readings.\(name) }") },
                          "`\(name)` 不是转发 —— 要么又存了一份，要么读口变了形状")
        }
    }

    /// 时间戳只有一份，且不参与观察。
    func testTheFrameTimeLivesInTheUnitAndIsNotObserved() throws {
        let unit = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionReadings.swift"))
        let lines = Self.codeLines(in: unit)
        guard let decl = lines.firstIndex(where: { $0.1.contains("var lastFrameAt") })
        else { return XCTFail("读数单元里没有 `lastFrameAt` —— 网络那一格会恒显示「—」") }
        let annotated = lines[decl].1.contains("@ObservationIgnored")
            || (decl > 0 && lines[decl - 1].1.contains("@ObservationIgnored"))
        XCTAssertTrue(annotated, "时间戳没带 `@ObservationIgnored` —— 每帧失效观察，合并刷新随之失效")

        let projection = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionProjection.swift"))
        let hits = Self.codeLines(in: projection).filter { $0.1.contains("lastFrameAt") }.map(\.0)
        XCTAssertEqual(hits, [], "投影还留着时间戳：行 \(hits) —— 两个时刻")
    }

    /// 读数那几条接线各一处、都在 `init` 里；两条直指单元。
    func testTheReadingsAreWiredAtTheAssemblyPoint() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let lines = Self.codeLines(in: code)
        guard let initAt = lines.firstIndex(where: { $0.1.contains("init(client: RpcClient") }),
              let endAt = lines[initAt...].firstIndex(where: { $0.1.contains("func deliver(") })
        else { return XCTFail("没找到 `init` 的边界 —— 判据的落点不对") }
        let initLine = lines[initAt].0
        let endLine = lines[endAt].0

        let wires = ["projection.onVerdict = ", "projection.onDataFrame = ",
                     "readings.onRefreshNeeded = ", "readings.onRebuildNeeded = ",
                     "projection.onRefreshNeeded = "]
        for wire in wires {
            let wired = lines.filter { $0.1.contains(wire) }
            XCTAssertEqual(wired.count, 1, "`\(wire)` 该恰好一处，实际 \(wired.count) 处")
            guard let line = wired.first else { continue }
            XCTAssertTrue(line.0 > initLine && line.0 < endLine,
                          "`\(wire)` 不在 `init` 里（第 \(line.0) 行）")
        }
        // 直指单元：写成 `{ [weak self] in self?.readings… }` 同样含类型名，只有捕获列表分得开。
        for wire in ["projection.onVerdict = ", "projection.onDataFrame = "] {
            guard let line = lines.first(where: { $0.1.contains(wire) }) else { continue }
            XCTAssertTrue(line.1.contains("[weak readings]"), "`\(wire)` 没直指读数单元：\(line.1)")
        }
    }

    /// 翻页把「视图有几条」交过去，不是常量；单元只构造一次。
    func testLoadOlderHandsTheVisibleCountToTheUnit() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let lines = Self.codeLines(in: code)
        XCTAssertTrue(lines.contains {
            $0.1.contains("readings.loadOlder(visibleNodeCount: { nodes.count })")
        }, "`loadOlder` 没把视图条数交过去 —— 传常量 0 的话每页都判成挤牙膏，拉满三页")
        let built = lines.filter { $0.1.contains("SessionReadings(") }.map(\.0)
        XCTAssertEqual(built.count, 1, "读数单元构造了 \(built.count) 次 —— 两次就有两份读数")
    }

    /// 读数单元不越层：不持投影、不持连接与订阅、不持快照、不持乐观行。
    func testTheReadingsHoldNoProjectionOrConnection() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionReadings.swift"))
        let lines = Self.codeLines(in: code)
        XCTAssertGreaterThan(lines.count, 100, "只扫到 \(lines.count) 行 —— 先怀疑路径")
        let forbidden = ["SessionProjection", "LongConnection", "ControlStream",
                         "ChatSnapshot", "SessionOptimist"]
        var hits: [String] = []
        for (line, text) in lines {
            for word in forbidden where text.contains(word) { hits.append("\(line):\(word)") }
        }
        XCTAssertEqual(hits, [], "读数单元拿了不属于它的东西：\(hits)")
    }

    /// 乐观行只由 `SessionOptimist` 持有。
    ///
    /// 编排层一旦还留一份，「哪一行该撤」就有第二个真源：两份都在推进时表现为偶发的
    /// 重复行或消息消失一帧，而编译期与运行时都看不出来。
    func testTheOptimisticRowsLiveOnlyInTheOptimist() throws {
        let sync = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let lines = Self.codeLines(in: sync)
        XCTAssertGreaterThan(lines.count, 120, "只扫到 \(lines.count) 行 —— 先怀疑路径")

        let names = ["PendingPrompt", "pendingPrompts", "settledPending", "pendingOrdinal"]
        let hits = lines.filter { line in names.contains { line.1.contains($0) } }.map(\.0)
        XCTAssertEqual(hits, [], "编排层还点着乐观行的类型名或存储：行 \(hits)")

        // 另一半：行与那本账真的有个持有者，否则上面那条可以靠「谁都不持有」变绿。
        // 断的是单元自己的名字（`entries` / `settled` / `ordinal`），不是编排层那四个。
        let unit = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionOptimist.swift"))
        let unitLines = Self.codeLines(in: unit)
        for name in ["var entries", "settled: Set<String>", "var ordinal"] {
            XCTAssertTrue(unitLines.contains { $0.1.contains(name) },
                          "乐观行单元里没有 \(name) —— 上面那条是空守")
        }
    }

    /// 三件事直连乐观行单元，不经编排层中转。
    ///
    /// 「只搬状态、没搬判定」正是这期要排除的形态：那样协调者仍是中间人，八条接线一条没少。
    func testTheThreeRowEventsGoStraightToTheOptimist() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionSync.swift"))
        let lines = Self.codeLines(in: code)
        for wire in ["projection.onSnapshotPublished = ", "projection.onDurableRecords = ",
                     "projection.onClaimedRow = "] {
            let wired = lines.filter { $0.1.contains(wire) }
            XCTAssertEqual(wired.count, 1, "`\(wire)` 该恰好一处，实际 \(wired.count) 处")
            guard let line = wired.first else { continue }
            // 断的是 `[weak optimist]` 而不是 `optimist`：写成 `{ [weak self] in self?.optimist… }`
            // 同样含那个词，而它正是这条判据要排除的「经协调者中转」。
            XCTAssertTrue(line.1.contains("[weak optimist]"),
                          "`\(wire)` 没直指乐观行单元 —— 协调者还是中间人：\(line.1)")
        }
        // 三个中转方法不该出现在编排层（声明与调用都算）。
        for gone in ["retireSettledPrompts", "settleDurableRecords", "claimRow"] {
            let left = lines.filter { $0.1.contains(gone) }.map(\.0)
            XCTAssertEqual(left, [], "编排层还留着 \(gone)：行 \(left)")
        }
    }

    /// 调度标志的顺序：关批、复位、再刷。
    ///
    /// 复位写在 `flushDue()` 的 `guard` 之后 —— early return 一旦走到，标志会永久为真、
    /// 此后不再合并；那之后每一次事件都各自物化一次。
    func testTheFlushResetsBeforeRefreshing() throws {
        let code = try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionDetail/Sync/State/SessionProjection.swift"))
        let lines = Self.codeLines(in: code)
        guard let gate = lines.firstIndex(where: { $0.1.contains("refreshGate.flushDue()") })
        else { return XCTFail("没找到 `flushDue()` —— 判据的落点不对") }
        let body = Array(lines[gate...].prefix(6))
        guard let reset = body.firstIndex(where: { $0.1.contains("flushScheduled = false") }),
              let refresh = body.firstIndex(where: { $0.1.contains("onRefreshNeeded") })
        else { return XCTFail("`flushDue()` 之后没看到复位或刷新 —— 取错了块") }
        XCTAssertLessThan(reset, refresh, "复位写在了刷新之后 —— early return 会让标志永久为真")
    }

    func testMenuSourcesBakeInNoLevelNames() throws {
        let files = Self.swiftFiles(under: sessionDetailRoot)
        XCTAssertGreaterThan(files.count, 10, "只扫到 \(files.count) 个文件 —— 先怀疑路径推算")
        // 只认带引号的字面量：注释里提到 low/high 不算内置，所以逐代码行判。
        let baked = ["\"low\"", "\"high\"", "\"max\""]
        for file in files {
            for (line, code) in Self.codeLines(in: try read(file)) {
                for literal in baked where code.contains(literal) {
                    XCTFail("\(file.lastPathComponent):\(line) 内置了档名字面量 \(literal)")
                }
            }
        }
    }

    func testSlashSourcesBakeInNoCommandNames() throws {
        let files = Self.swiftFiles(under: sessionDetailRoot)
        XCTAssertGreaterThan(files.count, 10, "只扫到 \(files.count) 个文件 —— 先怀疑路径推算")
        let names = ["permission", "compact", "export", "goal", "plan", "feedback"]
        let baked = names.flatMap { ["\"/\($0)\"", "\"\($0)\""] }
        for file in files {
            // 逐**代码行**判，跳过注释：注释里点名某个命令正是为了说「别内置它」。
            for (line, code) in Self.codeLines(in: try read(file)) {
                for literal in baked where code.contains(literal) {
                    XCTFail("\(file.lastPathComponent):\(line) 内置了命令名字面量 \(literal)")
                }
            }
        }
    }

    // MARK: - 丢弃要留痕

    /// 留痕句必须落在一条 `Log.warn(` 调用上，**不是只出现在文件里**。
    ///
    /// 整文件 `contains` 的失败方式：删掉日志那一行、在注释里留同一句话（解释为什么记
    /// 这一行），判据照样绿 —— 而它是这条路径唯一的证据。
    func testCancelWithoutEventIdLeavesAVisibleTrace() throws {
        let lines = Self.codeLines(in: try read(iosRoot.appendingPathComponent(
            "Sources/Features/Approval/State/ApprovalStore.swift")))
        XCTAssertTrue(
            lines.contains { $0.1.contains("Log.warn(") && $0.1.contains("dropped a cancel without an eventId") },
            "留痕句不在了（或只剩注释）—— 无寻址撤回被丢弃时现场只剩这一行")
    }

    func testDroppedListChangeLeavesAVisibleTrace() throws {
        let lines = Self.codeLines(in: try read(iosRoot.appendingPathComponent(
            "Sources/Features/SessionList/State/SessionListState.swift")))
        // 留痕只留给**这一族里认不出**的那一条。少了前缀分流，`$events` 上那些别的
        // 命名空间（插件装卸、设置文档）会被当成「本版不认识的列表事件」刷警告。
        XCTAssertTrue(
            lines.contains { $0.1.contains("SessionListEvents.claims(") },
            "前缀分流不在了 —— 别的命名空间的事件会被当成坏增量")
        XCTAssertTrue(
            lines.contains {
                $0.1.contains("Log.warn(") && $0.1.contains("a session event this build cannot read")
            },
            "留痕句不在了（或只剩注释）—— 坏增量被丢弃时现场只剩这一行")
    }

    // MARK: - 票不落盘

    /// 产品层不许把接入票写进任何文件 —— 它是登记凭据，换出节点身份之后就没有用途了。
    ///
    /// 守的是「被人顺手加回来」：票存一次，下次启动就会拿一把可能早已作废的票去注册，
    /// 而它的失败会被误认成网络问题。与「日志出口唯一」同源：能被随手加回来的东西得有人看着。
    func testTheTicketIsNeverWrittenToDisk() throws {
        let sources = Self.swiftFiles(under: iosRoot.appendingPathComponent("Sources"))
        XCTAssertGreaterThan(sources.count, 50, "只扫到 \(sources.count) 个源文件 —— 先怀疑路径推算")

        for file in sources {
            let text = try read(file)
            XCTAssertFalse(text.contains("TailnetKeyStore"),
                           "\(file.lastPathComponent) 又出现了票的存储类型 —— 票不落盘")
            guard file.lastPathComponent != "TailnetNode.swift" else { continue }
            XCTAssertFalse(text.contains("tailnet-key"),
                           "\(file.lastPathComponent) 提到了票的文件名 —— 只有迁移时的删除允许")
        }

        // 唯一允许落在**代码**里的地方：把老版本留下的那份删掉的那一行。
        // 注释里提它是说明，不算数 —— 所以先滤掉注释行再数。
        let node = try read(iosRoot.appendingPathComponent("Sources/Core/MeshNetwork/TailnetNode.swift"))
        let hits = node.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
            return !isComment && line.contains("tailnet-key")
        }
        XCTAssertEqual(hits.count, 1, "票的文件名只该出现在「删掉老残留」那一行代码里")
        XCTAssertTrue(hits.first?.contains("legacyTicketFile") == true,
                      "提到它的那一行必须是为了删除，不是为了写入")
    }

    // MARK: - 行为测试不许读仓库

    /// `ios/tests/` 跑在设备或模拟器上，那里没有仓库路径。谁在那边按 `#filePath` 推算根，
    /// 谁就会在真机上一片红 —— 这条把那条边界钉住，不靠人记。
    func testBehaviorTestsDoNotReadTheRepository() throws {
        let testsRoot = iosRoot.appendingPathComponent("tests")
        let files = Self.swiftFiles(under: testsRoot)
        XCTAssertGreaterThan(files.count, 20, "只扫到 \(files.count) 个测试文件 —— 先怀疑路径推算")
        for file in files {
            let text = try read(file)
            XCTAssertFalse(text.contains("fileURLWithPath: #filePath"),
                           "\(file.lastPathComponent) 按 #filePath 推算仓库根 —— 手机上读不到，"
                           + "这类断言属于判据 target")
        }
    }

    // MARK: - 网关声明的写 op 都要有可审计的客户端请求

    /// 客户端这一侧由**类型**表达：实现了 `AuditableRequest` 就是一次写操作，不再维护 op 名单。
    /// 所以这里从源码取两样 —— 哪些请求类型实现了那个协议、以及它们的端点名（`endpoint`）。
    ///
    /// **活性锚不用常量**：常量总落后于表（写 8 的时候表里已经有 9 条），落后一格恰好让
    /// 「漏读一个写端点」变成绿 —— 而那正是这条判据要抓的。这里直接数表里的 `write: true`
    /// 与客户端的 `extension …: AuditableRequest`，两边的解析结果必须与各自的标志数相等，
    /// 正则漏一条就当场对不上。
    func testClientCoversEveryWriteEndpointTheGatewayDeclares() throws {
        let declared = try gatewayWriteEndpoints()
        let flags = try gatewayWriteFlagCount()
        XCTAssertEqual(declared.count, flags,
                       "解析出 \(declared.count) 个写端点，表里有 \(flags) 处 `write: true` —— 正则漏了条目")
        // 下限随端点增减改这一处：它守的是「表里没有多出来的空号」，不是某个具体数量。
        // 当前 7 个 —— 第 3 期把两条应答端点换成了一条 `$events/result`。
        XCTAssertGreaterThanOrEqual(declared.count, 7,
                                    "只读到 \(declared.count) 个写端点 —— 先怀疑路径或正则")

        let covered = try auditableClientEndpoints()
        let extensions = try auditableExtensionCount()
        XCTAssertEqual(covered.count, extensions,
                       "客户端有 \(extensions) 处 `AuditableRequest`，只解析出 \(covered.count) 个端点名 —— "
                       + "先怀疑请求类型的正则")
        XCTAssertGreaterThanOrEqual(covered.count, 7,
                                    "只读到 \(covered.count) 个可审计端点 —— 先怀疑解析")

        let missing = declared.subtracting(covered)
        XCTAssertEqual(missing, [], "这些写端点客户端没有可审计的请求：\(missing.sorted())")
        // 反向：客户端记了审计、网关却当读端点的那些 —— 那会让「谁改了什么」多出
        // 一条什么都不改的记录，而它比漏记更难发现（审计看起来更"全"了）。
        let extra = covered.subtracting(declared)
        XCTAssertEqual(extra, [], "这些端点在客户端会留痕、但网关声明成读：\(extra.sorted())")
    }

    /// 网关声明的**写端点**清单。读的是端点表 —— 那是唯一判定处（`write: true` 那一格）。
    ///
    /// 一期之前这里读的是 `audit.ts` 的 `WRITE_OPS`；信封改造把那份清单删了，
    /// 判定只剩端点表一处。名字从旧 op 名换成了端点名 —— 判据两边都换，否则它读空。
    private func gatewayWriteEndpoints() throws -> Set<String> {
        let source = try read(repoRoot.appendingPathComponent(
            "gateway/src/protocol/unary-endpoints.ts"))
        let pattern = try NSRegularExpression(
            pattern: #"'([^'\s]+/[^'\s]+)':\s*\{\s*legacyOp:\s*'[^']*',\s*write:\s*(true|false)"#)
        let range = NSRange(source.startIndex..., in: source)
        var writes = Set<String>()
        for match in pattern.matches(in: source, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let flagRange = Range(match.range(at: 2), in: source) else { continue }
            if source[flagRange] == "true" { writes.insert(String(source[nameRange])) }
        }
        return writes
    }

    /// 端点表里 `write: true` 的条数 —— 与 `gatewayWriteEndpoints()` 互为活性锚。
    ///
    /// 只认**行首**的 `write: true`：表里每条端点的这个标志都独占一行。写法变了（挪到别的
    /// 字段后面、写成别的形状）时这里会少数，于是与解析结果对不上而红 —— 报的是
    /// 「先看标志的写法」，不是静默放过。
    private func gatewayWriteFlagCount() throws -> Int {
        let source = try read(repoRoot.appendingPathComponent(
            "gateway/src/protocol/unary-endpoints.ts"))
        return Self.codeLines(in: source).filter {
            $0.1.trimmingCharacters(in: .whitespaces)
                .range(of: #"^write:\s*true\b"#, options: .regularExpression) != nil
        }.count
    }

    /// 客户端可审计的**端点**名：请求类型实现了 `AuditableRequest`，且它的 `endpoint`
    /// 是个字面量（`static let endpoint = "…"`）。
    private func auditableClientEndpoints() throws -> Set<String> {
        let messages = try read(iosRoot.appendingPathComponent(
            "Sources/Core/Gateway/Rpc/Wire/RpcMessages.swift"))

        var endpointByType: [String: String] = [:]
        let structPattern = try NSRegularExpression(
            pattern: #"struct\s+(\w+)\s*:\s*GatewayRequest\b[^\n{]*\{([\s\S]*?)\n\}"#)
        let range = NSRange(messages.startIndex..., in: messages)
        for match in structPattern.matches(in: messages, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: messages),
                  let bodyRange = Range(match.range(at: 2), in: messages) else { continue }
            let body = String(messages[bodyRange])
            guard let endpoint = Self.literals(in: body, pattern: #"static let endpoint = "([^"]+)""#).first
            else { continue }
            endpointByType[String(messages[nameRange])] = endpoint
        }

        var auditable = Set<String>()
        for file in Self.swiftFiles(under: iosRoot.appendingPathComponent("Sources")) {
            guard let text = try? read(file) else { continue }
            auditable.formUnion(Self.literals(in: text, pattern: #"extension\s+(\w+)\s*:\s*AuditableRequest"#))
        }
        return Set(auditable.compactMap { endpointByType[$0] })
    }

    /// 源码里 `extension …: AuditableRequest` 的条数 —— 与解析出的端点数互为活性锚。
    private func auditableExtensionCount() throws -> Int {
        var count = 0
        for file in Self.swiftFiles(under: iosRoot.appendingPathComponent("Sources")) {
            guard let text = try? read(file) else { continue }
            count += Self.literals(in: text, pattern: #"extension\s+(\w+)\s*:\s*AuditableRequest"#).count
        }
        return count
    }

    private static func literals(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// 代码行：跳过整行注释（`//` / `*` / `/*` 开头）。行内注释不剥 —— 与其余判据同一口径。
    private static func codeLines(in text: String) -> [(Int, String)] {
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

    private static func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}

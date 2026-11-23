/**
 * 权限那一格的纯逻辑：名称映射、需确认的集合、`custom` 不可选、三面、以及「哪些事件该重读」。
 *
 * 取数与切换都是注入的闭包：不碰网关、不碰界面。期望值一律手写 —— 从实现推出来的期望
 * 等于没测。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class PermissionStateTests: XCTestCase {

    private func option(_ value: String, name: String? = nil) -> PermissionOption {
        PermissionOption(value: value, name: name ?? value)
    }

    private let three = [
        PermissionOption(value: "read-only", name: "read-only"),
        PermissionOption(value: "workspace-write", name: "workspace-write"),
        PermissionOption(value: "danger-full-access", name: "danger-full-access"),
    ]

    /// 一份目录：三档都在。
    private func catalog(options: [PermissionOption]? = nil) -> PermissionCatalog {
        PermissionCatalog(options: options ?? three,
                          defaultOptions: options ?? three,
                          defaultPreset: "workspace-write")
    }

    /// 投影里的当前档：`{permissions: {currentValue: …}}`。
    private func projection(_ current: String?) -> JSONValue {
        guard let current else { return .object(["permissions": .object([:])]) }
        return .object(["permissions": .object(["currentValue": .string(current)])])
    }

    /// 只回一份固定目录的状态对象；`select` 什么也不做（切换成功的形状）。
    private func readyState(current: String?, options: [PermissionOption]? = nil) async -> PermissionState {
        let state = PermissionState(fetch: { self.catalog(options: options) }, select: { _ in })
        state.noteProjection(projection(current))
        await state.reload()
        return state
    }

    // MARK: - O1 名称映射

    /// 宿主没配标签（`name == value`）时用我们那张中文表；宿主给了自定义名就原样用。
    ///
    /// 这一条同时钉住「内置 key 一个不漏」：加第四档而忘了补表，`default` 会把它变成
    /// `.host` 从而显示英文键 —— 判据在这里就红，而不是等真机上看见一个英文单词。
    func testLabelsFollowTheHostNameAndLocaliseOnlyBuiltIns() {
        let cases: [(String, String, PermissionLabel)] = [
            ("read-only", "read-only", .readOnly),
            ("workspace-write", "workspace-write", .workspaceWrite),
            ("danger-full-access", "danger-full-access", .fullAccess),
            ("auto", "auto", .autoReview),
            ("custom", "custom", .custom),
            // 宿主配了标签：让位，即使键是内置的。
            ("danger-full-access", "完全放开（自定义名）", .host("完全放开（自定义名）")),
            // 我们没见过的键：原样显示宿主给的名字，不猜中文。
            ("team-policy", "team-policy", .host("team-policy")),
        ]
        for (value, hostName, expected) in cases {
            XCTAssertEqual(PermissionState.label(of: value, hostName: hostName), expected,
                           "value=\(value) name=\(hostName)")
        }
        // 期望值的手写副本：中文那一层单独钉一次（上表只比枚举，不比字）。
        XCTAssertEqual(PermissionLabel.readOnly.text, "仅可查看")
        XCTAssertEqual(PermissionLabel.workspaceWrite.text, "工作区内修改")
        XCTAssertEqual(PermissionLabel.fullAccess.text, "完全权限")
        XCTAssertEqual(PermissionLabel.autoReview.text, "自动审查")
        XCTAssertEqual(PermissionLabel.custom.text, "自定义")
        XCTAssertEqual(PermissionLabel.host("团队策略").text, "团队策略")
    }

    // MARK: - O2 需确认的集合

    /// 恰好是「会放开限制的那两档」。多一档只是摩擦，少一档就是误触放开沙箱。
    func testConfirmationCoversExactlyTheTwoDangerousPresets() {
        let dangerous = ["danger-full-access", "auto"]
        let safe = ["read-only", "workspace-write", "custom", "team-policy"]
        for value in dangerous {
            XCTAssertTrue(PermissionState.needsConfirmation(value), value)
        }
        for value in safe {
            XCTAssertFalse(PermissionState.needsConfirmation(value), value)
        }
        // 需要确认的每一档都必须有确认文案 —— 否则用户点下去只看到一个没有正文的空框。
        for value in dangerous {
            let choice = PermissionState.Choice(
                value: value, label: .fullAccess, isSelected: false, needsConfirmation: true
            )
            XCTAssertNotNil(choice.confirmation, value)
        }
        let safeChoice = PermissionState.Choice(
            value: "read-only", label: .readOnly, isSelected: false, needsConfirmation: false
        )
        XCTAssertNil(safeChoice.confirmation, "不需要确认的档位不该有文案 —— 有就会被误用")
    }

    // MARK: - O3 custom 不可选

    /// `custom` 是显示态：它可以出现在目录里（协议没禁止），但绝不进可点项。
    func testCustomIsNeverAChoice() {
        let choices = PermissionState.choices(
            from: three + [option("custom")],
            current: "custom"
        )
        XCTAssertEqual(choices.map(\.value), ["read-only", "workspace-write", "danger-full-access"])
        // 它就是当前值也一样不可点 —— 「点一个不会生效的东西」比「看不到」更糟。
        XCTAssertFalse(choices.contains { $0.isSelected })
    }

    /// 当前档在目录里时只有它被标成选中；不在（`custom`）时一个都不标。
    func testSelectionMarksExactlyTheCurrentPreset() {
        let marked = PermissionState.choices(from: three, current: "workspace-write")
        XCTAssertEqual(marked.filter(\.isSelected).map(\.value), ["workspace-write"])

        let none = PermissionState.choices(from: three, current: "custom")
        XCTAssertTrue(none.filter(\.isSelected).isEmpty)
    }

    // MARK: - O4 三面

    /// 还没取过 = 等待面，那一格写 `--`；取到了 = 当前档的名字。
    func testOutcomeFaces() async {
        let waiting = PermissionState(fetch: { self.catalog() }, select: { _ in })
        XCTAssertEqual(waiting.outcome, .waiting)
        XCTAssertNil(waiting.currentLabel, "还没取过：不猜一个档位")
        XCTAssertEqual(PermissionState.unknownLabel, "--")

        let ready = await readyState(current: "read-only")
        XCTAssertEqual(ready.outcome, .ready)
        XCTAssertEqual(ready.currentLabel, .readOnly)

        let failed = PermissionState(fetch: { throw RpcClientError.notActivated }, select: { _ in })
        await failed.reload()
        XCTAssertEqual(failed.outcome, .failed(.offline), "传输失败归到 offline 那一档")
    }

    /// 重拉期间不把档位闪成 `--`：等待面下仍读上一次的值。
    func testReloadKeepsTheLastKnownValue() async {
        let state = await readyState(current: "workspace-write")
        // 直接再取一次会先置等待 —— 那一刻界面读的仍是上一份。
        let task = Task { await state.reload() }
        XCTAssertEqual(state.currentLabel, .workspaceWrite, "重拉开始时档位不该消失")
        await task.value
        XCTAssertEqual(state.currentLabel, .workspaceWrite)
    }

    /// 切档失败不改变「当前是哪档」，只留一句失败原因。
    func testAFailedSwitchKeepsTheCurrentValue() async {
        let state = PermissionState(
            fetch: { self.catalog() },
            select: { _ in throw RpcClientError.refused(GatewayFailure(code: "unknown-command", message: "gone")) }
        )
        state.noteProjection(projection("read-only"))
        await state.reload()
        let accepted = await state.choose("workspace-write")
        XCTAssertFalse(accepted)
        XCTAssertEqual(state.currentLabel, .readOnly, "失败时不乐观更新")
        XCTAssertEqual(state.failure, .refused(GatewayFailure(code: "unknown-command", message: "gone")))
        XCTAssertNotNil(state.failureLine)
    }

    // MARK: - O5 能力缺席与目录为空

    /// `options` 缺席 = 没有权限服务（不画那一格）；空数组 = 服务在但没配（格子照画）。
    func testAbsentOptionsHidesTheCellWhileAnEmptyCatalogKeepsIt() async {
        let absent = await readyState(current: "read-only",
                                      options: []) // 空数组：服务在
        XCTAssertTrue(absent.showsCell, "空数组 = 服务在、一项没配：格子照画，点开是空的")
        XCTAssertTrue(absent.choices.isEmpty)

        // 三键一起缺席 = 这个装配没有权限服务。
        let missing = PermissionState(fetch: { PermissionCatalog() }, select: { _ in })
        await missing.reload()
        XCTAssertFalse(missing.showsCell, "没有权限服务时不画这一格")

        // 等待面照画：还没拿到不等于没有这个能力。
        let waiting = PermissionState(fetch: { self.catalog() }, select: { _ in })
        XCTAssertTrue(waiting.showsCell)
    }

    /// 当前档只从投影来：`permissions.currentValue`。
    ///
    /// 缺键、空串、类型不对一律 `nil`（界面显示 `--`）—— **缺席不是默认档**。
    func testTheCurrentPresetComesFromThePermissionsProjection() {
        XCTAssertEqual(PermissionState.currentValueOf(projection("workspace-write")), "workspace-write")
        XCTAssertNil(PermissionState.currentValueOf(.object(["permissions": .object([:])])))
        XCTAssertNil(PermissionState.currentValueOf(.object([:])), "整个 permissions 格缺席")
        XCTAssertNil(PermissionState.currentValueOf(projection("")), "空串不是一档")
        XCTAssertNil(PermissionState.currentValueOf(.object(["permissions": .object(["currentValue": .number(1)])])),
                     "类型不对时也不猜")
    }

    // MARK: - O6 事件回流

    /// 只有那三类事件值得重读目录。别的类型重读等于把会话变成一串请求。
    func testOnlyPermissionEventsMarkTheCurrentValueStale() {
        for type in ["permission/preset", "sandbox/mode", "approval/policy"] {
            XCTAssertTrue(PermissionState.affectsCurrent(type), type)
        }
        for type in ["assistant/message", "user/message", "command/done", "usage", "turn/end", ""] {
            XCTAssertFalse(PermissionState.affectsCurrent(type), type)
        }
    }
}

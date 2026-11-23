/**
 * 权限那一格：**两个来源**，与一条写路径。
 *
 * - 目录（进程级）来自 `permissionPresets/catalog`：这个装配能选什么。
 * - 当前档（会话级）来自 `permissions` 投影：`session/control` 推过来，键是 `currentValue`。
 * - 切档走 `commands/execute` 的 `/permission <preset>` —— 与 Web UI 同一条路。
 *
 * **两源不合成一条读**：合成过一次，结果是「目录新、当前值旧」而界面看不出哪一半是旧的。
 * 也不折叠沙箱模式与审批策略 —— 那两个 knob 在宿主侧，客户端在结构上算不出第二份答案。
 */
import Foundation

/// 一个档位的显示标签。**只有形状，没有文字** —— 中文在 `Display/PermissionText.swift`。
///
/// 分出 `.host` 那一支是为了让「宿主给了自定义名」与「我们认得的内置档」在类型上就不同：
/// 前者原样显示，后者才轮到我们那张表。
enum PermissionLabel: Equatable {
    case readOnly
    case workspaceWrite
    case fullAccess
    case autoReview
    /// 「当前组合对不上任何预设」的显示态。只显示，永不出现在可点项里。
    case custom
    /// 宿主给的自定义名 —— 原样显示。
    case host(String)
}

@MainActor
@Observable
final class PermissionState {
    /// 屏幕上要落成的三种面。**只描述目录**那一半：当前档是另一路（`current`），
    /// 它到了就显示，目录还在拉也照样有值。
    enum Outcome: Equatable {
        /// 还没有结果，或正在重拉 —— 「等待」不是「没有权限」。
        case waiting
        /// 拿到了目录。`options` 为空数组是成功面（服务在、一项都没配）。
        case ready
        /// 没拿到。原因只有两档，分法与状态行的失败同源。
        case failed(Cause)
    }

    /// 失败的原因。**不带句子**：说给用户听的那句在 `Display/PermissionText.swift`。
    enum Cause: Equatable {
        /// 服务端按信封拒绝 —— 协议值原样带。
        case refused(GatewayFailure)
        /// 没连上网关（传输失败、组网未激活、身份不可用）。
        case offline
    }

    /// 一个可点的档位。
    struct Choice: Equatable, Identifiable {
        let value: String
        let label: PermissionLabel
        let isSelected: Bool
        /// 选它之前要不要过一次确认 —— 危险档位不误触。
        let needsConfirmation: Bool
        var id: String { value }
    }

    private(set) var outcome: Outcome = .waiting
    /// 上一次成功拿到的目录。**重拉期间与失败之后都还读它**：格子不该因为「重新取一次」
    /// 把选项闪成空。
    private(set) var catalog: PermissionCatalog? = nil
    /// 当前档 —— 来自投影。**`nil` = 宿主还没说**（界面显示 `--`），不是「默认档」。
    private(set) var current: String? = nil
    /// 最近一次切档失败的原因；成功后清空。与 `outcome` 分开 —— 切失败不改变「当前是哪档」。
    private(set) var failure: Cause? = nil

    private let fetch: @MainActor () async throws -> PermissionCatalog
    private let select: @MainActor (String) async throws -> Void

    /// 本机发起过的最新一次代号：重拉与切档共用一个 —— 后发起者胜，晚到的旧回包不许覆盖。
    private var generation = 0
    /// 一次合并窗口内只排一次重读：一次切档会连着到几条事件。
    private var reloadScheduled = false
    private static let mergeWindowNanos: UInt64 = 16_000_000

    init(fetch: @escaping @MainActor () async throws -> PermissionCatalog,
         select: @escaping @MainActor (String) async throws -> Void) {
        self.fetch = fetch
        self.select = select
    }

    // MARK: - 取数与切换

    /// 取一次目录。重试与方向事件回流都走这里：先把面置回等待，避免「旧选项还挂着，看不出在重拉」。
    func reload() async {
        generation += 1
        let mine = generation
        outcome = .waiting
        do {
            let catalog = try await fetch()
            guard mine == generation else { return }
            self.catalog = catalog
            failure = nil
            outcome = .ready
        } catch {
            guard mine == generation else { return }
            outcome = .failed(Self.cause(of: error))
        }
    }

    /// 投影里到了这个会话的最新值。**只认 `permissions.currentValue`** —— 其余键是别人的事。
    ///
    /// 由 `SessionSync` 的投影口转发进来（它已经按会话挑过），所以这里不再判会话身份。
    func noteProjection(_ values: JSONValue) {
        current = Self.currentValueOf(values)
    }

    /// 切到一档。**不乐观更新**：显示等投影回来，失败时那一格保持原值。
    ///
    /// `ok` 只表示**宿主的命令被受理**；落地证据是投影（`permissions.currentValue`）。
    @discardableResult
    func choose(_ preset: String) async -> Bool {
        generation += 1
        let mine = generation
        do {
            try await select(preset)
            guard mine == generation else { return false }
            failure = nil
            return true
        } catch {
            guard mine == generation else { return false }
            failure = Self.cause(of: error)
            return false
        }
    }

    /// 宿主的预设目录变了（`permission-presets/catalog-changed`）：重读目录。
    ///
    /// 目录是全局的、与当前会话无关；当前档走投影，不在这里。
    func noteCatalogChanged() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            await self.reload()
        }
    }

    /// 会话里到了一条事件。只认那三类（切档与它连带的两个 knob）—— 它们同样会带来
    /// 目录层面的变化（宿主可能换了可选项），所以重读一次目录。
    ///
    /// 当前档不靠这条：网关把这三类列为投影触发源，投影会自己到。
    func noteLiveEvent(type: String) {
        guard Self.affectsCurrent(type) else { return }
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.mergeWindowNanos)
            guard let self else { return }
            self.reloadScheduled = false
            await self.reload()
        }
    }

    // MARK: - 折值

    /// 功能条上要不要画这一格。
    ///
    /// 目录里 `options` 缺席 = 这个装配没有权限服务 —— 那是唯一一种「不画」。
    /// 等待与失败期间照画：它们只是「还没拿到」，不是「没有这个能力」。
    var showsCell: Bool {
        if case .ready = outcome { return catalog?.options != nil }
        return true
    }

    /// 当前档位的标签；宿主不知道时 `nil`（界面显示 `--`）。
    var currentLabel: PermissionLabel? {
        guard let current else { return nil }
        let hostName = catalog?.options?.first { $0.value == current }?.name ?? current
        return Self.label(of: current, hostName: hostName)
    }

    /// 菜单里能点的项。「自定义」永远不在其中。
    var choices: [Choice] {
        Self.choices(from: catalog?.options ?? [], current: current)
    }

    // MARK: - 纯规则（判据直接打这里，不构造网络）

    /// 「对不上任何预设」的显示态。宿主与客户端各有一份同名判定，这里只用来过滤。
    static let customValue = "custom"

    /// 投影里的当前档：`{permissions: {currentValue: "…"}}`。
    ///
    /// 缺键、类型不对、空串一律 `nil` —— **缺席不是默认档**，界面显示 `--` 而不是猜一个。
    static func currentValueOf(_ values: JSONValue) -> String? {
        guard let value = values["permissions"]?["currentValue"]?.string, !value.isEmpty else { return nil }
        return value
    }

    /// 一个预设的显示标签。
    ///
    /// **宿主给了自定义名就让位**：只有当 `name` 就是键本身（宿主没配标签）时，才用我们
    /// 这张内置表。否则用户会在设置页与手机上看到两个名字。
    static func label(of value: String, hostName: String) -> PermissionLabel {
        guard hostName == value else { return .host(hostName) }
        switch value {
        case "read-only": return .readOnly
        case "workspace-write": return .workspaceWrite
        case "danger-full-access": return .fullAccess
        case "auto": return .autoReview
        case customValue: return .custom
        default: return .host(hostName)
        }
    }

    /// 选它之前要不要确认。只有会放开限制的那两档需要 —— 其余档位直接切，多一次模态只是摩擦。
    static func needsConfirmation(_ value: String) -> Bool {
        value == "danger-full-access" || value == "auto"
    }

    /// 这条事件说明「宿主那边的目录或当前权限可能变了」。
    ///
    /// 当前档由投影推来（网关那边已把这三类事件列为投影重读的触发源），所以这里只用来
    /// **重读目录**：目录随插件装卸变，而插件装卸不一定发投影。其余类型一律不动 ——
    /// 每一条消息都重读一次，等于把一次会话变成一串一元请求。
    static func affectsCurrent(_ eventType: String) -> Bool {
        affectingEventTypes.contains(eventType)
    }

    private static let affectingEventTypes: Set<String> = [
        "permission/preset", "sandbox/mode", "approval/policy",
    ]

    /// 目录里的项 → 可点项。`custom` 滤掉：它是「当前组合对不上任何预设」的显示态，
    /// 列出来就是让用户点一个不会生效的东西。
    static func choices(from options: [PermissionOption], current: String?) -> [Choice] {
        options
            .filter { $0.value != customValue }
            .map { option in
                Choice(
                    value: option.value,
                    label: label(of: option.value, hostName: option.name),
                    isSelected: option.value == current,
                    needsConfirmation: needsConfirmation(option.value)
                )
            }
    }

    /// 失败 → 两档原因，与 `CommandDirectory` 同一分法。
    private static func cause(of error: any Error) -> Cause {
        if let error = error as? RpcClientError, case .refused(let failure) = error {
            return .refused(failure)
        }
        return .offline
    }
}

/// 拉一次目录。每次打开菜单与每次目录变更事件都拉：目录随插件装配变。
@MainActor
func fetchPermission(_ client: RpcClient) async throws -> PermissionCatalog {
    let response: PermissionCatalogResponse = try await client.perform(PermissionCatalogRequest())
    return PermissionCatalog(options: response.options,
                             defaultOptions: response.defaultOptions,
                             defaultPreset: response.defaultPreset)
}

/// 切一档：发一行 `/permission <preset>`。
///
/// `ok` = **宿主的命令已受理**；落地证据是投影（`permissions.currentValue`），
/// 这一发不返回「现在是什么」—— 回包里没有那一格，也就无从把发出去的那份当答案。
@MainActor
func selectPermission(_ client: RpcClient, agentId: String, preset: String) async throws {
    try await runCommand(client, agentId: agentId, line: "/permission \(preset)")
    // 与命令通道同一条理由：这是这一屏唯一能放开沙箱限制的动作，发给谁、发什么必须留痕。
    Log.info(Log.Module.session, "permission-select", ["agent": agentId, "preset": preset])
}

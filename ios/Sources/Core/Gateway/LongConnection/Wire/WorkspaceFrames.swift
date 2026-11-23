/**
 * 组流的线上形状 —— 与网关 `wire/workspace-stream.ts` 对着看，改字段那边必须同改。
 *
 * **只声明客户端真读的字段。** 上游的 `WorkspaceView` 还有 `path` / `createdAt` /
 * `updatedAt`：手机一个都不显示，也不按路径归并（归属看 `sessionIds`）。声明它们等于给
 * 每一帧加三个会让整帧解不出的必填项，而读的人看不出「这三格其实没用」。
 *
 * 与 `session/control` 的 `baseline` **同名不同形** —— 那是投影表，这是组清单。
 * 解码因此按流做：`WorkspaceItem.read` 只认这一条流的七种货物，别的流的 `baseline`
 * 落 `foreign`（见 `CargoReading`）。
 */
import Foundation

/// 一个组 —— 上游 `WorkspaceView` 里客户端读的那三格。
struct WorkspaceView: Decodable, Equatable, Identifiable {
    let workspaceId: String
    /// 组名（宿主由目录名派生，不改写）。
    let title: String
    /// 归属这个组的会话，按手工顺序。**归属的唯一来源**：不按目录再算一遍。
    let sessionIds: [String]

    /// `Identifiable` 要的那一格。线上叫 `workspaceId`，这里不另起名字。
    var id: String { workspaceId }
}

/// 一次连接的完整状态 —— 上游 `WorkspaceBaseline` 的三格。
struct WorkspaceBaseline: Decodable, Equatable {
    let items: [WorkspaceView]
    let archivedSessionIds: [String]
    /// 最近置顶的在前。
    let pinnedSessionIds: [String]
}

/// 组流的七种货物 —— **只有这条流认这七样**。
///
/// `baseline` 与 `replace` 同形不同义：前者是一代的开口，后者替换这一代里已经发过的一切。
/// 两者在客户端都按「整份替换」处理 —— 组没有可增量合并的稳定身份（顺序会变），
/// 合并只会把已经删掉的组留在屏上。
enum WorkspaceItem {

    case baseline(WorkspaceBaseline)
    case replace(WorkspaceBaseline)
    case upsert(WorkspaceView)
    case remove(workspaceId: String)
    case order(workspaceIds: [String])
    case archived(sessionIds: [String])
    case pinned(sessionIds: [String])

    static func read(_ value: JSONValue) -> CargoReading<WorkspaceItem> {
        switch value["type"]?.string {
        case "baseline":
            return baseline(value).map { .decoded(.baseline($0)) } ?? .unparsable
        case "replace":
            return baseline(value).map { .decoded(.replace($0)) } ?? .unparsable
        case "upsert":
            let view = try? WorkspaceView(from: JSONValueDecoder(value["workspace"] ?? .null))
            return view.map { .decoded(.upsert($0)) } ?? .unparsable
        case "remove":
            return idOf(value, key: "workspaceId").map { .decoded(.remove(workspaceId: $0)) } ?? .unparsable
        case "order":
            return strings(value["workspaceIds"]).map { .decoded(.order(workspaceIds: $0)) } ?? .unparsable
        case "archived":
            return strings(value["archivedSessionIds"]).map { .decoded(.archived(sessionIds: $0)) } ?? .unparsable
        case "pinned":
            return strings(value["pinnedSessionIds"]).map { .decoded(.pinned(sessionIds: $0)) } ?? .unparsable
        default:
            return .foreign(value["type"]?.string)
        }
    }

    /// `baseline` / `replace` 的载荷都在 `value` 那一格里。
    private static func baseline(_ value: JSONValue) -> WorkspaceBaseline? {
        try? WorkspaceBaseline(from: JSONValueDecoder(value["value"] ?? .null))
    }

    private static func idOf(_ value: JSONValue, key: String) -> String? {
        guard let id = value[key]?.string, !id.isEmpty else { return nil }
        return id
    }

    /// 一串 id。`[String]` 解不出（有非字符串项）时整帧算 `unparsable` —— 半个集合比没有更坏。
    private static func strings(_ value: JSONValue?) -> [String]? {
        guard let array = value?.array else { return nil }
        var ids: [String] = []
        for item in array {
            guard let id = item.string else { return nil }
            ids.append(id)
        }
        return ids
    }
}

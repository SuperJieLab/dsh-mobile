/**
 * 会话列表那一屏的写动作：让宿主建一个空会话、让宿主造一个工作空间、删掉一个工作空间。
 *
 * 与 `SessionDetail/State/SessionWrites.swift` 分开：那边是「往一个已存在的会话里写」，
 * 这边是「让一个会话或一个工作空间存在 / 不再存在」。失败域不同，合成一个入口会让
 * 「哪个会话」这个问题在一半的路径上没有答案。
 *
 * 名字的合法性**不在这里判**：`WorkspaceName` 是那条规则的家，调用方在发请求之前用它。
 */
import Foundation

/// 一次创建工作空间的结果。`alreadyExists` 不是失败 —— 那个工作空间已经在那儿了。
enum WorkspaceCreation: Equatable {
    case created
    case alreadyExists
    case failed(String)
}

/// 宿主造出来的那个工作空间。
///
/// 三格都要：`created` 决定界面说哪句话，`workspaceId` 与 `title` 让列表在重拉之前
/// 就能把它摆出来（重拉可能撞在一次在途请求上，那一撞什么也不拉）。
struct WorkspaceCreated: Equatable {
    let workspaceId: String
    let title: String
    let created: Bool
}

/// 让宿主造一个工作空间：在固定根下建目录并注册。
///
/// 名字里用 `make` 而不是 `create`：状态层那个动作叫 `createWorkspace(name:)`（它是
/// 用户按下去的那件事），这里是它落到线上去的那一半 —— 两者同名会让调用点看起来在
/// 递归。
///
/// 同名**不报错**（`created` 为假）—— 那正是用户想要的：那个工作空间已经在那儿了。
@MainActor
func makeWorkspace(_ client: RpcClient, name: String) async throws -> WorkspaceCreated {
    let response: WorkspaceCreateResponse = try await client.perform(WorkspaceCreateRequest(name: name))
    guard let workspaceId = response.workspaceId,
          let title = response.title,
          let created = response.created else {
        throw RpcClientError.malformedResponse(detail: "workspaceId/title/created")
    }
    // 与网关那一侧同名的一格：界面据 `created` 说两句不同的话，日志里没有它，
    // 「我以为建了新的、其实命中旧的」这种投诉就查不出来。
    Log.info(Log.Module.workspace,
             "workspace-create \"\(name)\" → \(workspaceId) (\(created ? "created" : "already existed"))")
    return WorkspaceCreated(workspaceId: workspaceId, title: title, created: created)
}

/// 让宿主建一个空会话，返回它的 id。
///
/// `ok` 意为**建出来或复用了一个空会话**，不是「进去了」—— 进去靠导航，不靠列表。
/// `workspaceId` 为 `nil` 时目录由宿主自己决定（这条 op 在本功能之前唯一的行为）；
/// 给了就落在那个工作空间里，归属由宿主挂进成员表。
@MainActor
func createBlankSession(_ client: RpcClient, in workspaceId: String?) async throws -> String {
    let response: SessionCreateResponse = try await client.perform(
        SessionCreateRequest(workspaceId: workspaceId))
    guard let sessionId = response.sessionId else {
        throw RpcClientError.malformedResponse(detail: "sessionId")
    }
    // 落在哪儿是这条 op 唯一的变量；不带工作空间那条老路径会落宿主的当前目录，
    // 而那个目录在手机上完全看不见 —— 将来「新建的会话不知道去哪了」时靠这一行。
    Log.info(Log.Module.workspace,
             "session-create in \(workspaceId ?? "<host default cwd>") → \(sessionId)")
    return sessionId
}

/// 让宿主解除一个工作空间的注册。**目录与会话日志都不动** —— 它们失去的只是归属。
///
/// 没有业务字段要读：回包的 `ok` 由 `perform` 里的信封校验保证，非 ok 会抛
/// `RpcClientError.refused`。删一个已经不存在的同样走成功路径（网关认得 not-found）——
/// 用户的意图是「让它不在列表里」，那已经是事实。
///
/// 名字用 `remove` 而不是 `delete`：状态层那个动作叫 `deleteWorkspace(_:)`，两者同名会让
/// `convenience init` 里的调用被解析成实例方法（`makeWorkspace` 与 `createWorkspaceAction`
/// 也是同一个理由）。
@MainActor
func removeWorkspace(_ client: RpcClient, workspaceId: String) async throws {
    _ = try await client.perform(
        WorkspaceDeleteRequest(workspaceId: workspaceId)) as WorkspaceDeleteResponse
    // 成功只有一条路（回包的 `ok` 由信封校验保证），但它是**破坏性动作**的收尾：
    // 用户说「我删了但组还在」时，得能证明这一发真的到了网关并成功了。
    Log.info(Log.Module.workspace, "workspace-delete accepted", ["workspace": workspaceId])
}

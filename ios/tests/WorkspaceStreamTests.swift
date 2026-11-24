/**
 * 组流收端（`WorkspaceStream`）：七种帧折成组清单与两个集合。
 *
 * 这里测的是**折法**：`baseline` 与 `replace` 都是整份替换、`upsert` 同 id 只留一项、
 * `order` 按新顺序排但**不丢**没提到的组、`archived` / `pinned` 只动两个集合。
 *
 * 帧一律从线上文本进来（`InboundFrame.decode`），不直接构造货物 —— 判别字段、`value`
 * 那一层与按流解码都在判据里。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class WorkspaceStreamTests: XCTestCase {

    private func frame(_ value: String) throws -> InboundFrame {
        let text = #"{"type":"item","streamId":"g1","value":\#(value)}"#
        return try XCTUnwrap(InboundFrame.decode(Data(text.utf8)), "这一帧该解得开：\(value)")
    }

    /// 把一帧喂给收端。
    @discardableResult
    private func feed(_ stream: WorkspaceStream, _ value: String) throws -> StreamReply {
        stream.handle(try frame(value))
    }

    private let baseline = """
    {"type":"baseline","value":{"items":[
      {"workspaceId":"w-1","path":"/x/记账","title":"记账","sessionIds":["s-1","s-2"],
       "createdAt":"2026-11-20T10:00:00.000Z","updatedAt":"2026-11-22T09:00:00.000Z"},
      {"workspaceId":"w-2","path":"/x/试验","title":"试验","sessionIds":[],
       "createdAt":"2026-11-20T10:00:00.000Z","updatedAt":"2026-11-22T09:00:00.000Z"}],
      "archivedSessionIds":["s-9"],"pinnedSessionIds":["s-1"]}}
    """

    /// `baseline` 是一次全量：组清单、两个集合都落地，并且**这条流从此刻建成**。
    func testBaselineEstablishesTheStreamWithEveryCollection() throws {
        let stream = WorkspaceStream()

        let reply = try feed(stream, baseline)

        XCTAssertTrue(reply.establishes, "baseline 是这条流的开口帧 —— 开流超时靠它清")
        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-1", "w-2"])
        XCTAssertEqual(stream.workspaces.first?.sessionIds, ["s-1", "s-2"])
        XCTAssertEqual(stream.archivedSessionIds, ["s-9"])
        XCTAssertEqual(stream.pinnedSessionIds, ["s-1"])
    }

    /// `replace` 与 `baseline` 同形，但**不是**开口帧；语义是整份替换 —— 旧组一个都不留。
    ///
    /// 这条是核心：增量合并的写法会把 w-2 留在屏上，而它在宿主那边已经没了。
    func testReplaceSwapsTheWholeListAndDoesNotEstablish() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)

        let reply = try feed(stream, """
        {"type":"replace","value":{"items":[
          {"workspaceId":"w-3","title":"新的","sessionIds":["s-3"]}],
          "archivedSessionIds":[],"pinnedSessionIds":[]}}
        """)

        XCTAssertFalse(reply.establishes, "replace 是同一代里的替换，不是新的开口帧")
        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-3"], "旧组整批换掉")
        XCTAssertTrue(stream.archivedSessionIds.isEmpty)
        XCTAssertTrue(stream.pinnedSessionIds.isEmpty)
    }

    /// 整份里出现两条同 id 的组：**只留第一项，不崩**。
    ///
    /// 宿主不该给出重键（注册表按 id 索引），但这一层收的是对端的字节。旧写法在
    /// `order` 帧按 id 建索引时是 `Fatal error` —— 一条坏数据让 App 退出，而这一层的
    /// 纪律是「坏帧丢弃并留痕」。去重之后最坏也只是少一项。
    func testADuplicateWorkspaceIdInTheBaselineKeepsTheFirstAndDoesNotCrash() throws {
        let stream = WorkspaceStream()

        try feed(stream, """
        {"type":"baseline","value":{"items":[
          {"workspaceId":"w-1","title":"先到的","sessionIds":["s-1"]},
          {"workspaceId":"w-1","title":"后到的","sessionIds":["s-2"]}],
          "archivedSessionIds":[],"pinnedSessionIds":[]}}
        """)

        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-1"], "同 id 只留一项")
        XCTAssertEqual(stream.workspaces.first?.title, "先到的", "留第一次出现的那一项 —— 与 upsert 的「后到覆盖」不同，这里没有可信的后到")
        XCTAssertEqual(stream.workspaces.first?.sessionIds, ["s-1"])

        // 正控：`order` 帧仍能正常工作（旧写法在这一步崩）。
        try feed(stream, #"{"type":"order","workspaceIds":["w-1"]}"#)
        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-1"])
    }

    /// `order` 帧里出现重复 id：**只认一次**，不留两条同 id 的组。
    ///
    /// 与 baseline 重键同一条理由（身份重复），但入口不同：`order` 只带 id 列表，
    /// 它自己不校验重复。旧写法在这一步会按 id 建索引（重复键 `Fatal error`）。
    func testADuplicateIdInAnOrderFrameDoesNotDuplicateTheGroup() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)   // w-1, w-2

        try feed(stream, #"{"type":"order","workspaceIds":["w-2","w-2","w-1"]}"#)

        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-2", "w-1"],
                       "帧内的重复 id 只认第一次 —— 列两次就是两条同身份的组")
    }

    /// `upsert` 同一个 id 只留一项；新 id 追加到末尾（顺序由 `order` 帧校正）。
    func testUpsertUpdatesInPlaceOrAppends() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)

        try feed(stream, #"{"type":"upsert","workspace":{"workspaceId":"w-1","title":"记账（改名）","sessionIds":["s-1"]}}"#)
        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-1", "w-2"], "同一个组不该变成两项")
        XCTAssertEqual(stream.workspaces.first?.title, "记账（改名）")
        XCTAssertEqual(stream.workspaces.first?.sessionIds, ["s-1"], "成员表整份换")

        try feed(stream, #"{"type":"upsert","workspace":{"workspaceId":"w-9","title":"新组","sessionIds":[]}}"#)
        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-1", "w-2", "w-9"], "新组追加在末尾")
    }

    func testRemoveDropsTheGroupAndLeavesTheOthers() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)

        try feed(stream, #"{"type":"remove","workspaceId":"w-1"}"#)

        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-2"])
        // 删组不动两个集合：归档与置顶是会话的属性，不是组的。
        XCTAssertEqual(stream.archivedSessionIds, ["s-9"])
        XCTAssertEqual(stream.pinnedSessionIds, ["s-1"])
    }

    /// `order` 只重排，不丢组：帧里没提到的留在末尾。
    ///
    /// 丢一组的表现是「这个组在 Mac 上有、手机上没了」；顺序错只是顺序错 —— 两者不能同解。
    func testOrderReordersAndKeepsGroupsTheFrameDoesNotMention() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)

        try feed(stream, #"{"type":"order","workspaceIds":["w-2"]}"#)

        XCTAssertEqual(stream.workspaces.map(\.workspaceId), ["w-2", "w-1"],
                       "提到的按新顺序在前，没提到的保留在末尾")
    }

    /// `archived` / `pinned` 只改两个集合，**组清单一动不动**。
    func testArchivedAndPinnedOnlyTouchTheirSets() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)
        let before = stream.workspaces

        try feed(stream, #"{"type":"archived","archivedSessionIds":["s-2","s-3"]}"#)
        try feed(stream, #"{"type":"pinned","pinnedSessionIds":["s-3","s-1"]}"#)

        XCTAssertEqual(stream.workspaces, before, "两个集合的变化不该碰组清单")
        XCTAssertEqual(stream.archivedSessionIds, ["s-2", "s-3"])
        XCTAssertEqual(stream.pinnedSessionIds, ["s-3", "s-1"], "顺序有意义：最近置顶的在前")
    }

    /// 客户端半边：`session/control` 的 `baseline` 喂给组流 → 不认识、丢弃，
    /// 且**不改任何状态**。
    ///
    /// 两者同名不同形（投影表 vs 组清单）。共用一个解码器时，这里会解成空组清单 ——
    /// 界面上是「所有组突然消失」。
    func testAControlBaselineIsForeignHere() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)
        let before = stream.workspaces

        try feed(stream, #"{"type":"baseline","value":{"projections":{"s-1":{"asOfSeq":3,"values":{}}}}}"#)

        XCTAssertEqual(stream.workspaces, before, "不是本流的 baseline 不该被当成组清单")
        XCTAssertEqual(stream.archivedSessionIds, ["s-9"])
    }

    /// 是本流的 type、字段坏了 → 丢弃并留痕；状态不动。
    func testABrokenCargoLeavesTheStateAlone() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)
        let before = stream.workspaces

        try feed(stream, #"{"type":"remove"}"#)                              // 缺 workspaceId
        try feed(stream, #"{"type":"order","workspaceIds":["w-1",42]}"#)      // 混了非字符串
        try feed(stream, #"{"type":"upsert","workspace":{"workspaceId":"w-9"}}"#) // 缺 title/sessionIds

        XCTAssertEqual(stream.workspaces, before, "坏帧不得改动任何一格")
    }

    /// 终态拒绝之后**已知的组一个都不清**：界面保持断开前的值。
    ///
    /// 清空会让「组流断了」表现成「所有组都没了」—— 用户看到的是数据丢失，而实际上
    /// 只是这条流停了。列表的显示不依赖这条流活着。
    func testATerminalRefusalKeepsTheLastKnownGroups() throws {
        let stream = WorkspaceStream()
        try feed(stream, baseline)
        let before = stream.workspaces

        let reply = stream.handle(InboundFrame(
            type: "error", streamId: "g1",
            failure: GatewayFailure(code: GatewayErrorCode.unauthenticated.rawValue, message: "no", details: [:])))

        XCTAssertEqual(reply.next, .stop)
        XCTAssertEqual(stream.workspaces, before, "断开不等于清空")
        XCTAssertEqual(stream.archivedSessionIds, ["s-9"], "两个集合同样保留")
    }

    /// `end` 重开；终态拒绝收起（可再挂），可重试拒绝按退避再试。
    func testEndReopensAndRefusalsFollowTheirRetryability() throws {
        let stream = WorkspaceStream()

        XCTAssertEqual(stream.handle(InboundFrame(type: "end", streamId: "g1")).next, .reopen)

        let terminal = InboundFrame(type: "error", streamId: "g1",
                                    failure: GatewayFailure(code: GatewayErrorCode.unauthenticated.rawValue,
                                                            message: "no", details: [:]))
        XCTAssertEqual(stream.handle(terminal).next, .stop)

        let retryable = InboundFrame(type: "error", streamId: "g1",
                                     failure: GatewayFailure(code: GatewayErrorCode.internalError.rawValue,
                                                             message: "later", details: [:]))
        XCTAssertEqual(stream.handle(retryable).next, .retry)
    }
}

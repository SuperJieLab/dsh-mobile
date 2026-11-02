/**
 * 删除确认框上的两句话。
 *
 * 它们不是顺手写的中文：宿主的语义是「解注册、保留目录与会话日志」，而**用户看到
 * 「删除」两个字时默认理解的是「项目没了」**。这三件事必须出现在确认框里，否则他会
 * 以为自己刚才删掉的是一个目录。
 */
import XCTest

@testable import DshMobile

final class WorkspaceDeletionTextTests: XCTestCase {

    func testTheTitleNamesTheWorkspaceBeingDeleted() {
        XCTAssertTrue(WorkspaceDeletionText.title(for: "记账 App").contains("记账 App"),
                      "确认框要点名 —— 「确定删除吗」这种问法不知道自己删的是哪一个")
    }

    /// 无论有没有会话，这两句都得在。
    func testTheMessageAlwaysSaysTheDirectorySurvives() {
        for count in [0, 1, 7] {
            let text = WorkspaceDeletionText.message(sessionCount: count)
            XCTAssertTrue(text.contains("目录"), "「\(count) 条会话」那份文案没说目录 —— 用户会以为项目被删了")
            XCTAssertTrue(text.contains("不会被删除"), "说了目录但没说它不会被删，等于没说")
        }
    }

    /// 「里面的会话会去哪」只在真有会话时说。
    func testTheMessageNamesTheUngroupedDestinationOnlyWhenThereAreSessions() {
        XCTAssertFalse(WorkspaceDeletionText.message(sessionCount: 0).contains("未分组"),
                       "空组说「会话会移到未分组」是错的 —— 它一条都没有")

        let withSessions = WorkspaceDeletionText.message(sessionCount: 2)
        XCTAssertTrue(withSessions.contains("未分组"), "有会话时必须说清它们去哪，否则用户以为跟着没了")
        XCTAssertTrue(withSessions.contains("2"), "数量要说出来 —— 「一些会话」让人不知道丢了多少")
    }
}

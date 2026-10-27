/**
 * 显示面（`Stage`）的四个组合 —— 穷举，不抽样。
 *
 * 它是整个初始流程的岔路口：错一支，用户就看到不该看的那一面。最糟的一支是「网不通却
 * 显示列表」—— 那时列表永远空、页脚写着「等待组网就绪…」，而唯一能修的地方在别处。
 */
import XCTest

@testable import DshMobile

final class StageTests: XCTestCase {

    /// 组网没就绪 —— 无论有没有身份，都是「先修网」。
    ///
    /// 这一支不看身份是故意的：网不通时不管有没有凭证，能做的都只有修网。「已配对但断网」
    /// 因此落在同一面，不需要额外分支，也不该因为有凭证就显示一个永远空的列表。
    func testUnreadyMeshAlwaysNeedsMesh() {
        let notReady: [MeshPhase] = [.needsSetup, .connecting, .failed(.badKey), .failed(.unreachable)]
        for phase in notReady {
            XCTAssertEqual(Stage.resolve(meshPhase: phase, isPaired: true), .needsMesh,
                           "组网未就绪（\(phase)）且已配对时，该显示组网页")
            XCTAssertEqual(Stage.resolve(meshPhase: phase, isPaired: false), .needsMesh,
                           "组网未就绪（\(phase)）且未配对时，该显示组网页")
        }
    }

    /// 组网就绪：有没有身份决定配对面还是列表。
    func testReadyMeshDependsOnIdentity() {
        XCTAssertEqual(Stage.resolve(meshPhase: .ready, isPaired: false), .needsPairing,
                       "就绪但没身份时，该显示配对页")
        XCTAssertEqual(Stage.resolve(meshPhase: .ready, isPaired: true), .ready,
                       "就绪且已配对时，该显示主界面")
    }
}

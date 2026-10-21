/**
 * 输入框那一行的判定：能发吗、面板开不开、发出去之后草稿留不留。
 *
 * 断言只喂一个投递闭包 —— 与 `ComposerState` 的构造同形，不必起网关。
 * 重点是**两条路的草稿处置不同**：受理了才清，没送到就留着（`unknown-command` 是本期唯一
 * 用户能自己改好的失败）。
 */
import XCTest

@testable import DshMobile

@MainActor
final class ComposerStateTests: XCTestCase {

    /// 空草稿不能发；只有空白也不能发。
    func testBlankDraftCannotSubmit() async {
        let composer = ComposerState()
        XCTAssertFalse(composer.canSubmit)
        composer.text = "   \n "
        XCTAssertFalse(composer.canSubmit, "只剩空白等于没写")

        var delivered = 0
        let accepted = await composer.submit { _ in delivered += 1; return true }
        XCTAssertFalse(accepted, "空白不发")
        XCTAssertEqual(delivered, 0, "空白一个字都没送出去")
    }

    /// 受理之后草稿清空。
    func testAcceptedSubmissionClearsTheDraft() async {
        let composer = ComposerState()
        composer.text = "/compact"
        var saw: SlashDispatch?
        let accepted = await composer.submit { dispatch in saw = dispatch; return true }

        XCTAssertTrue(accepted)
        XCTAssertEqual(saw, .command("/compact"), "斜杠那行走命令通道")
        XCTAssertEqual(composer.text, "", "受理了才清 —— 屏幕上那行字该消失")
    }

    /// **没送到时草稿原样留着** —— 名字打错是唯一用户能自己改好的失败。
    func testRejectedSubmissionKeepsTheDraft() async {
        let composer = ComposerState()
        composer.text = "/nosuchcmd"
        let accepted = await composer.submit { _ in false }

        XCTAssertFalse(accepted)
        XCTAssertEqual(composer.text, "/nosuchcmd", "命令名打错：整行留着，改一个字就能重按")
        XCTAssertFalse(composer.isSubmitting, "投递结束，按钮该恢复")
    }

    /// 面板的查询串与分流的判定读**同一份归一化文本**。
    ///
    /// `" /per"` 归一化之后是 `/per`：面板要弹（否则用户看不到候选），而发送时会走命令通道。
    /// 两处各读一份原始草稿时，这一行会让面板判「不在敲命令」而发送判「是命令」。
    func testPaletteAndRoutingAgreeOnLeadingWhitespace() async {
        let composer = ComposerState()
        composer.text = " /per"
        XCTAssertEqual(composer.paletteQuery, "per", "前导空格归一化后仍然是「在敲命令」")

        var saw: SlashDispatch?
        _ = await composer.submit { dispatch in saw = dispatch; return true }
        XCTAssertEqual(saw, .command("/per"), "同一行确实走了命令通道 —— 两边不矛盾")
    }

    /// 面板只在「还在敲名字」时开；带参数的行要收起（否则候选会挡住用户写参数）。
    func testPaletteClosesOnceArgumentsStart() {
        let composer = ComposerState()
        composer.text = "/permission "
        XCTAssertNil(composer.paletteQuery, "已经在写参数：面板收起")
        composer.text = "/permission read-only"
        XCTAssertNil(composer.paletteQuery)
    }

    /// 普通消息不开面板。
    func testPlainTextDoesNotOpenThePalette() {
        let composer = ComposerState()
        composer.text = "看下 src/Core 目录"
        XCTAssertNil(composer.paletteQuery, "路径里的斜杠不是命令")
    }

    /// 选中一条只回填，不执行 —— 而且回填之后面板要收起（否则盖住刚填好的那一行）。
    func testPickingFillsTheDraftWithoutSubmitting() async {
        let composer = ComposerState()
        composer.text = "/per"
        composer.pick(name: "permission")

        XCTAssertEqual(composer.text, "/permission ", "名字 + 一个尾空格，便于直接补参数")
        XCTAssertNil(composer.paletteQuery, "回填之后已经不在敲名字，面板该收起")

        var delivered = 0
        _ = await composer.submit { _ in delivered += 1; return true }
        XCTAssertEqual(delivered, 1, "回填本身不投递；是 submit 那一次")
    }

    /// 投递期间连按不会发两次。
    func testConcurrentSubmitsDoNotDeliverTwice() async {
        let composer = ComposerState()
        composer.text = "/compact"
        var delivered = 0
        // 第一次投递在闭包里再触发一次 submit —— 此时 isSubmitting 已经是 true。
        let inner = await composer.submit { dispatch in
            delivered += 1
            let second = await composer.submit { _ in delivered += 1; return true }
            XCTAssertFalse(second, "在途期间第二次提交不该被受理")
            _ = dispatch
            return true
        }
        XCTAssertTrue(inner)
        XCTAssertEqual(delivered, 1, "只送出去一次")
    }
}

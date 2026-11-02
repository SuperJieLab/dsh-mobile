/**
 * 工作空间名字的规则。
 *
 * 这一份与网关那份（`mac-gateway/src/wire/workspace.ts`）是**同一张表的两次实现** ——
 * 客户端在提交前就要拦下、不发请求，服务端又不信任客户端，所以两边都必须有。对齐靠
 * 下面这组字面量逐字相同，不靠「记得同步」。
 */
import Foundation
import XCTest

@testable import DshMobile

final class WorkspaceNameTests: XCTestCase {

    /// 与网关侧逐字相同的一组样本。加样本时两边一起加。
    private let refused = ["", "   ", "a/b", "a\\b", ".", "..", " a/b "]
    private let accepted = ["记账 App", "a b", ".config", "项目-1", "test-r41"]

    func testBlanksSeparatorsAndDotEntriesAreRefused() {
        for name in refused {
            XCTAssertNotNil(WorkspaceName.problem(with: name), "「\(name)」应当被拒")
        }
    }

    func testSpacesInsideDotPrefixAndNonASCIIAreAccepted() {
        for name in accepted {
            XCTAssertNil(WorkspaceName.problem(with: name), "「\(name)」应当被接受")
        }
    }

    func testTheRuleLooksAtTheTrimmedName() {
        XCTAssertNil(WorkspaceName.problem(with: "  记账  "), "首尾空白不是名字的一部分")
        XCTAssertEqual(WorkspaceName.trimmed("  记账  "), "记账", "发出去的是 trim 过的那个")
        XCTAssertNotNil(WorkspaceName.problem(with: "  a/b  "), "首尾空白不得把分隔符藏起来")
    }

    func testEachProblemIsDistinguishable() {
        XCTAssertEqual(WorkspaceName.problem(with: ""), .blank)
        XCTAssertEqual(WorkspaceName.problem(with: "a/b"), .pathSeparator)
        XCTAssertEqual(WorkspaceName.problem(with: ".."), .dotEntry)
    }
}

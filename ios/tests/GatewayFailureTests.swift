/**
 * 一处判据：`GatewayFailure.isRetryable` 的取值**恰好**是那两个会自己好的码。
 *
 * 这条原来住在 `EventStreamTests` 里（那时流层还认识 `GatewayErrorCode`）。拆流之后
 * 那个判断从流层搬到了错误值自己身上，判据跟着搬 —— 它守的事没变：**多一个或少一个，
 * 都要有人重新判一次「再开一条同样的流，上游的答复会不会变」**。
 *
 * 为什么用 `allCases` 穷举而不是逐条断言「这两个是、那些不是」：后者在新加一个错误码时
 * 不会红，而「新码该不该重试」正是最容易被忘掉的一次判断。
 */
import Foundation
import XCTest

@testable import DshMobile

final class GatewayFailureTests: XCTestCase {

    private func failure(_ code: GatewayErrorCode) -> GatewayFailure {
        GatewayFailure(code: code.rawValue, message: "")
    }

    func testTheRetryableCodesAreExactlyTheTwoThatCanHeal() {
        let retryable = GatewayErrorCode.allCases
            .filter { failure($0).isRetryable }
            .map(\.rawValue)
            .sorted()
        XCTAssertEqual(retryable, [
            GatewayErrorCode.internalError.rawValue,
            GatewayErrorCode.sourceUnavailable.rawValue,
        ].sorted(), "可重试的码恰好两个 —— 多一个会让人无限重试，少一个会让该重开的流直接收起")
    }

    /// 上游可能加码：收到的是 `String`，认不出的码一律不可重试。
    ///
    /// 「不认识就当可重试」会让一个真正的终态被反复重开；反过来的代价只是多一次重连。
    func testAnUnknownCodeIsNotRetryable() {
        XCTAssertFalse(GatewayFailure(code: "some-future-code", message: "").isRetryable)
    }
}

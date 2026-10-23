/**
 * 模型目录三面的映射 —— 成功 / 协议拒绝 / 传输失败与重试。
 *
 * 取数入口是注入的闭包：不碰网关、不碰界面，也不依赖模拟器的网络栈。三条断言只回答两件事：
 * 一次取数的结果落成哪一面、失败的原因带的是什么（原文有没有丢）。
 *
 * 这三条守的是同一件事：目录失败时屏幕上给的是服务端原文并可重试，不是一句「不可用」。
 */
import Foundation
import XCTest

@testable import DshMobile

@MainActor
final class ModelCatalogStateTests: XCTestCase {

    /// 按剧本回放的取数入口：每次调用取下一个结果，用完之后一直抛「组网未激活」。
    private final class Script {
        private var steps: [Result<ModelCatalog, any Error>]

        init(_ steps: [Result<ModelCatalog, any Error>]) {
            self.steps = steps
        }

        func next() throws -> ModelCatalog {
            guard !steps.isEmpty else { throw RpcClientError.notActivated }
            return try steps.removeFirst().get()
        }
    }

    /// 弱引用盒子：让取数闭包在跑的时候能读到状态对象自己的面 —— 验证「每次取数开始时是等待」。
    private final class WeakBox {
        weak var value: ModelCatalogState?
    }

    private func makeCatalog(default model: String?) -> ModelCatalog {
        ModelCatalog(
            default: model.map { ModelSelection(provider: "p", model: $0) },
            groups: [
                ModelCatalogGroup(
                    id: "p", name: "Provider",
                    models: [ModelCatalogEntry(id: "m", name: "M")]
                )
            ],
            failures: nil
        )
    }

    /// 成功面不丢字段 —— 默认值原样带过来。
    func testReadyKeepsDefaults() async {
        let state = ModelCatalogState(fetch: { self.makeCatalog(default: "m") })
        XCTAssertEqual(state.outcome, .waiting, "还没取过：等待面，不是空目录")

        await state.reload()

        XCTAssertEqual(state.outcome, .ready(makeCatalog(default: "m")), "成功后是内容面")
        guard case .ready(let list) = state.outcome else { return }
        XCTAssertEqual(list.default?.model, "m", "目录默认值原样带过来")
        XCTAssertEqual(list.groups?.first?.models.first?.id, "m", "分组与条目原样带过来")
    }

    /// 协议拒绝原样带，认不出的码要显示服务端原文。
    func testRefusedKeepsServerText() async {
        let failure = GatewayFailure(code: "catalog-unavailable", message: "模型目录服务没起来")
        let state = ModelCatalogState(fetch: { throw RpcClientError.refused(failure) })

        await state.reload()

        XCTAssertEqual(state.outcome, .failed(.refused(failure)), "协议拒绝原样带过去")
        guard case .failed(let cause) = state.outcome else { return }
        XCTAssertTrue(cause.line.contains("模型目录服务没起来"),
                      "认不出的协议码要回落服务端原文，不能只剩一句「目录没取到」")
    }

    /// 传输失败落在传输面；重试期间是等待面，成功之后回到内容面。
    func testOfflineThenRetry() async {
        let script = Script([
            .failure(RpcClientError.notActivated),
            .success(makeCatalog(default: "m")),
        ])
        let box = WeakBox()
        var seen: [ModelCatalogState.Outcome] = []
        let state = ModelCatalogState(fetch: {
            if let current = box.value?.outcome { seen.append(current) }
            return try script.next()
        })
        box.value = state

        await state.reload()
        XCTAssertEqual(state.outcome, .failed(.offline), "没连上网关 → 传输面")

        await state.reload()
        XCTAssertEqual(state.outcome, .ready(makeCatalog(default: "m")), "重试成功后回到内容面")
        XCTAssertEqual(seen, [.waiting, .waiting], "每次取数开始时都先把面置回等待")
    }
}

/**
 * 会话列表那一屏的写动作：让宿主建一个空会话。
 *
 * 与 `SessionDetail/State/SessionWrites.swift` 分开：那边是「往一个已存在的会话里写」，
 * 这边是「让一个会话存在」。失败域不同，合成一个入口会让「哪个会话」这个问题在一半的
 * 路径上没有答案。
 */
import Foundation

/// 让宿主建一个空会话，返回它的 id。
///
/// `ok` 意为**建出来或复用了一个空会话**，不是「进去了」—— 进去要靠列表读回那一行。
/// 目录不由我们给（宿主用自己的当前目录），所以这里没有参数。
@MainActor
func createBlankSession(_ client: RpcClient) async throws -> String {
    let response: SessionCreateResponse = try await client.perform(SessionCreateRequest())
    guard let sessionId = response.sessionId else {
        throw RpcClientError.malformedResponse(detail: "sessionId")
    }
    return sessionId
}

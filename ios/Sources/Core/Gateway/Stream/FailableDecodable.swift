/**
 * 容错数组元素（R4 决定 1）：解不出的元素落 `nil` 而不是让整个数组报废。
 *
 * 存在的理由是 M6 的「切片照实退化，不猜」在解码层的落点——opening 的一条坏事件
 * 只该少显示一条，不该把整屏拖垮。调用方用 `compactMap(\.value)` 收好的那些。
 */
import Foundation

struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}

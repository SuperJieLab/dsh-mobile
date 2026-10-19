/**
 * 容错数组元素：解不出的元素落 `nil` 而不是让整个数组报废。
 *
 * opening 里的一条坏事件只该少显示一条，不该把整屏拖垮 —— 协议承诺事件体原样透传，
 * 我们认不出的形状迟早会出现在数组里。调用方用 `compactMap(\.value)` 收好的那些。
 */
import Foundation

struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}

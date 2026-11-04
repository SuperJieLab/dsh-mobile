import Foundation

/// 带版本号的载荷封套：`{"v": N, "payload": {…}}`。
///
/// 为什么要有它：载荷的形状会随版本变，读的人必须先知道「手里这份是哪一版」才能决定
/// 怎么读。没有它，唯一的选择是「按当前形状读，读不出就当没有」—— 那就是**删了重来**。
///
/// **载荷不强类型化**（是 `Data` 而不是某个 `Codable`）：迁移函数要处理的是**非当前版本**的形状，
/// 而那些类型早就不在了。只有字节才读得动它们。
enum VersionedPayload {

    /// 一份读出来的载荷。
    struct Stored: Equatable {
        /// 没有 `v` 的裸 JSON 记为 0 —— 那是「建封套之前」的格式，也是这个机制自己的第一次迁移。
        let version: Int
        let payload: Data
    }

    /// 从存的文本里读出来。
    ///
    /// 裸 JSON（没有 `v`）记为版本 0，不算坏 —— 那是老格式，由迁移链负责往上走。
    /// 认不出是 JSON 对象时返回 `nil`，由调用方决定那是「没有」还是「坏了」。
    static func read(_ text: String) -> Stored? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let rawVersion = object["v"] else {
            // 没有封套：整份就是载荷，版本按 0 算。
            return Stored(version: 0, payload: data)
        }
        guard let version = rawVersion as? Int, version >= 0,
              let payload = object["payload"],
              JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }

        return Stored(version: version, payload: payloadData)
    }

    /// 一路迁到 `target`。
    ///
    /// `steps` 的键是**来源**版本：`steps[2]` 把 v2 变成 v3。
    /// **缺一步就返回 `nil`** —— 迁不动的时候不能猜，猜出来的配置会让节点连错地方。
    static func migrate(
        _ stored: Stored,
        to target: Int,
        steps: [Int: (Data) -> Data?]
    ) -> Data? {
        guard stored.version <= target else { return nil }

        var payload = stored.payload
        var version = stored.version
        while version < target {
            guard let step = steps[version], let next = step(payload) else { return nil }
            payload = next
            version += 1
        }
        return payload
    }

    /// 把载荷包成封套。
    static func envelope(version: Int, payload: Data) -> Data? {
        guard let body = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        return envelope(version: version, payloadObject: body)
    }

    /// 同上，载荷已经是 JSON 对象时用这个（迁移函数手里通常就是这个形状）。
    static func envelope(version: Int, payloadObject: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(payloadObject) else { return nil }
        let boxed: [String: Any] = ["v": version, "payload": payloadObject]
        return try? JSONSerialization.data(withJSONObject: boxed)
    }
}

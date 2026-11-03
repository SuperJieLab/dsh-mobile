/**
 * 「上次注册用的是哪一家控制面」—— tsnet 状态目录里的身份属于谁。
 *
 * 状态目录是一包不透明文件，它自己不说「我是 headscale 的」还是「我是官方的」。而换控制面
 * 之后旧身份仍留在里面：状态机若只看「目录在不在」，切过去照样报「已入网」，节点拿旧身份
 * 去连新控制面，表现成「连上了但什么都通不了」。
 *
 * 所以注册成功后把当时的控制面记下来，启动时比对。记在 UserDefaults 而不是 tsnet 目录里：
 * 那是宿主自己的文件，我们不去塞东西；而两边一起消失的路径（重装 App）本来就一致。
 */
import Foundation

enum ControlPlaneRecord {

    /// 记下的那一格。值是一个归一后的地址串。
    private static let key = "mesh.registeredControlURL"

    /// 归一：尾斜杠不算差别 —— `https://x:8443` 与 `https://x:8443/` 是同一个控制面。
    ///
    /// 只做这一项归一：路径、端口、大小写都有意义，多归一样就会把「真的换了」判成「没换」。
    static func normalize(_ url: URL?) -> String? {
        guard let url else { return nil }
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// 注册成功后记下这一次用的控制面。
    ///
    /// 地址解不出来时**不记**：记一个错的值会让下一次启动判成「换了控制面」而白清一遍状态目录。
    static func save(_ url: URL?, defaults: UserDefaults = .standard) {
        guard let text = normalize(url) else { return }
        defaults.set(text, forKey: key)
    }

    /// 记下的控制面是不是就是这一个。
    ///
    /// **没记录过 = 匹配**：老版本升上来时状态目录里躺着有效身份，不该因为「我们刚开始记」
    /// 就重注册一遍 —— 那会把一次升级变成一次掉线。
    static func matches(_ url: URL?, defaults: UserDefaults = .standard) -> Bool {
        guard let recorded = defaults.string(forKey: key) else { return true }
        return recorded == normalize(url)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

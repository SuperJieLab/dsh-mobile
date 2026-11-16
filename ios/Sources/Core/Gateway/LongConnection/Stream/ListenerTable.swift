/**
 * 一条流上的听众表：同一个入口可以挂多个，按身份退订。
 *
 * 为什么抽出来：两条连接级流各要一份（代次一个、货物一个），而「按 token 退订」这件事
 * 抄第二遍时最容易漏的是**退订闭包里的弱引用** —— 漏了就是「听众比流活得久」，
 * 而那个症状只在流被换掉之后才出现。
 *
 * 与 `Notifier` 一类不同：它不合并、不防抖，`fire` 就是按注册顺序同步叫一遍。
 * 合并会让「这一次代次我没看到」变成可能，而恢复的界线必须一帧不落。
 */
import Foundation

@MainActor
final class ListenerTable<T> {

    private struct Entry {
        let token: UUID
        let call: (T) -> Void
    }

    private var entries: [Entry] = []

    /// 挂一个听众。
    ///
    /// @returns 退订 token。**每个入口都给**：多读者必须能退订，否则「先于进程消失的
    ///   消费方」只能靠闭包捕获的对象被弱引用掉来停止 —— 那不是一种保证。
    @discardableResult
    func add(_ call: @escaping (T) -> Void) -> () -> Void {
        let token = UUID()
        entries.append(Entry(token: token, call: call))
        return { [weak self] in
            self?.entries.removeAll { $0.token == token }
        }
    }

    func fire(_ value: T) {
        for entry in entries {
            entry.call(value)
        }
    }
}

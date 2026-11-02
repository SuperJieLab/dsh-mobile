/**
 * 哪些组被点开了 —— 一个本机偏好，默认全折。
 *
 * 只回答「用户点过哪些组」，**不回答「该不该展开」**：没有「新建后自动展开」这条规则
 * （折叠的组上不提供「新建会话」，所以那个状态不会出现），这一层因此没有任何判定。
 *
 * 存的是**展开了的**那些，与默认值（折）互补。名字与上游同一件事同名
 * （`ui-workspace` 的 `groupExpansion`）：存什么，名字就说什么。
 */
import Foundation

struct GroupExpansion: Equatable {

    /// 被点开的组的 id。不在里面就是折的。
    private(set) var expanded: Set<String>

    /// 偏好键。带版本号：形状若变，旧值自然读不出来，退化为默认而不是被误读。
    static let defaultsKey = "sessionlist.expandedGroups.v1"

    init(expanded: Set<String> = []) {
        self.expanded = expanded
    }

    func isExpanded(_ groupId: String) -> Bool {
        expanded.contains(groupId)
    }

    /// 切换一个组。**没有单向的 `expand` / `collapse`**：唯一的调用方是切换，单向方法在
    /// 本期没有任何消费者，而空着的容器是这类代码里最先腐坏的部分。
    mutating func toggle(_ groupId: String) {
        if expanded.contains(groupId) {
            expanded.remove(groupId)
        } else {
            expanded.insert(groupId)
        }
    }

    /// 只留下当前还在的组。由调用方在**写盘前**调用，而不是在拉取列表时 —— 后者会让一次
    /// 读变成一个可能有写副作用的动作。
    mutating func retain(among groupIds: Set<String>) {
        expanded.formIntersection(groupIds)
    }

    /// 读本机偏好。缺失与损坏都退化为「全折叠」—— 它不影响任何正确性，不为它做三态；
    /// 但**损坏要留痕**：`mesh.config` 读不出来会报一句，这一份如果静默退化，
    /// 「我点开的组怎么又收起来了」就查不到原因（症状与「用户自己折的」完全一样）。
    ///
    /// 判损坏的办法只能是「键在、但读不成字符串数组」—— `stringArray` 对这种情形与
    /// 「没存过」都回 `nil`，两者靠 `object(forKey:)` 区分。
    static func load(from defaults: UserDefaults = .standard) -> GroupExpansion {
        guard let stored = defaults.stringArray(forKey: defaultsKey) else {
            if defaults.object(forKey: defaultsKey) != nil {
                Log.warn(Log.Module.workspace,
                         "\(defaultsKey) is not a string array — falling back to all collapsed")
            }
            return GroupExpansion()
        }
        return GroupExpansion(expanded: Set(stored))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Array(expanded), forKey: Self.defaultsKey)
    }
}

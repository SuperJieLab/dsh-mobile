/**
 * 删除确认框上的文案。
 *
 * 宿主的语义是「解注册，保留目录与其中每一个会话日志」，而**用户看到「删除」两个字时
 * 默认理解的是「项目没了」**。所以这三件事必须写出来，且不能只在某一句里写 ——
 * 有没有会话是两种不同的后果，两句各自都要说清「目录还在」。
 *
 * 住在 `Display/` 而不是视图里：它是可判定的（`WorkspaceDeletionTextTests`），而内联在
 * 视图里的句子没有任何东西守着，改字时删掉半句不会有人发现。
 */
enum WorkspaceDeletionText {

    /// 确认框的标题。点名是必须的 —— 「确定删除吗」不知道自己删的是哪一个。
    static func title(for name: String) -> String {
        "删除「\(name)」？"
    }

    /// 确认框的正文。
    ///
    /// @param sessionCount - 组里的会话数。0 条时不提「未分组」：那时没有会话要挪。
    static func message(sessionCount: Int) -> String {
        let survives = "这只会从列表里移除它，Mac 上的目录和其中的文件不会被删除。"
        guard sessionCount > 0 else { return survives }
        return "\(survives)里面的 \(sessionCount) 个会话会移到「未分组」。"
    }
}

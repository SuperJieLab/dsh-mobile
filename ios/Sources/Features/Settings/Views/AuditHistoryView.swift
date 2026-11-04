import SwiftUI

/// 写操作的历史：谁在什么时候改了什么。
///
/// 与设置页的「导出诊断包」分工不同 —— 那个带走的是**过程**（日志、崩溃、性能摘要），
/// 给排障用；这一屏列的是**结果**，给「那次到底是谁删的」这类问题用。两者不是同一种东西，
/// 所以不合在一处。
struct AuditHistoryView: View {

    let log: AuditLog

    /// 读一次就够：审计只追加，重进这一屏时再读。
    @State private var entries: [AuditEntry] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && entries.isEmpty {
                Text("还没有写操作。")
                    .foregroundStyle(.secondary)
            }
            // 用下标做 id：两条记录可能逐字相同（同一毫秒、同 op、同目标），
            // 拿内容做标识会让 List 认错行。
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                row(entry)
            }
        }
        .navigationTitle("操作历史")
        .task {
            entries = log.recent(50)
            loaded = true
        }
    }

    private func row(_ entry: AuditEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.op)
                    .font(.callout.monospaced())
                Spacer()
                Text(verdict(entry.result))
                    .font(.caption)
                    .foregroundStyle(entry.result == .ok ? .secondary : Color.red)
            }
            Text(entry.at, format: .dateTime.month().day().hour().minute().second())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.target)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 拒绝时把码一起显示：`refused` 说的是「没改成」，码说的是**为什么** ——
    /// 少它就得回去翻日志，而这一屏存在的理由正是「不用翻日志」。
    private func verdict(_ outcome: AuditResult) -> String {
        switch outcome {
        case .ok: return "ok"
        case .refused(let code): return "refused · \(code)"
        }
    }
}

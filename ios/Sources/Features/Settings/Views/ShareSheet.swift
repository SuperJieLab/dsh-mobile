import SwiftUI
import UIKit

/// 一次导出的诊断包。`URL` 本身不是 `Identifiable`，而 `.sheet(item:)` 要一个 ——
/// 每次导出都是新的一份，所以用 `UUID` 做身份，而不是用路径（同秒两次导出路径会撞）。
struct ExportedBundle: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系统分享面板。
///
/// 用 `UIActivityViewController` 而不是 `ShareLink`：后者要求 item 在求值时就有，
/// 而诊断包是「点了才生成」的（生成要读文件，是 I/O）。求值时生成会让每次重绘都写一次盘。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

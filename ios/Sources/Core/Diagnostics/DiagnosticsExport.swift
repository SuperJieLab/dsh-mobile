import Foundation

/// 把诊断包文本落成文件，交给分享面板带走。
///
/// 落临时目录：它是一次性的交付物，用户分享完就该消失，而不是攒在 App 里。
enum DiagnosticsExport {

    /// 写一份，返回文件地址。同名会被时间戳区分开 —— 两次导出不该互相覆盖。
    static func write(_ text: String, at date: Date = Date()) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let stamp = Int(date.timeIntervalSince1970)
        let url = directory.appendingPathComponent("dsh-diagnostics-\(stamp).txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}

extension DiagnosticsBundle {

    /// 机器的内部型号（如 `iPhone17,1`）。
    ///
    /// 用 `sysctlbyname` 而不是 `UIDevice`：判定层不许 import UIKit，而机型是诊断要的
    /// 事实之一（不同机型的内存与 GPU 差得远，同一个崩溃在不同机型上的复现率不同）。
    /// 内部型号够用 —— 它唯一确定机型，而「iPhone 16 Pro」这种名字要一张映射表。
    static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}

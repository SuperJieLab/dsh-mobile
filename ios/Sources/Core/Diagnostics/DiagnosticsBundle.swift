import Foundation

/// 诊断包的文本：一次跑的环境、日志尾巴、遥测原文。
///
/// 纯函数 —— 输入是全部输入，输出是一段文本。这样「包里到底有什么」可以被判据逐字看见，
/// 而不用真的去跑一次导出。
struct DiagnosticsBundle {

    /// 组装所需的全部材料。设备与版本由调用方填：这一层不引 UIKit。
    struct Input {
        let generatedAt: Date
        let appVersion: String
        let appBuild: String
        let system: String
        let device: String
        /// 组网现状：阶段、路径、隧道产物在不在。一眼能看，不必从日志尾巴里倒推。
        let mesh: String
        let logTail: String
        /// 遥测原文：文件名 + 内容。新的在前。
        let telemetry: [(name: String, text: String)]
    }

    /// 组装成一段可直接分享的纯文本。
    ///
    /// 不分文件、不打包 zip：分享面板对纯文本的支持最稳，而「打开就能读」比「要先解压」
    /// 在排障时值钱得多。
    static func text(_ input: Input) -> String {
        var out = ""
        out += "=== dsh-mobile 诊断包 ===\n"
        out += "生成时间：\(LogTimestamp.string(from: input.generatedAt))\n"
        out += "App：\(input.appVersion) (\(input.appBuild))\n"
        out += "系统：\(input.system)\n"
        out += "设备：\(input.device)\n"

        out += "\n=== 组网 ===\n\(input.mesh)\n"

        out += "\n=== 日志（最近的尾巴）===\n"
        // 日志逐行脱敏：这里才是「导出包里不含凭据」真正生效的地方 ——
        // 靠调用点自觉不打印凭证，是保证不了任何事的。
        for line in input.logTail.split(separator: "\n", omittingEmptySubsequences: false) {
            out += redact(String(line)) + "\n"
        }

        if input.telemetry.isEmpty {
            out += "\n=== 遥测 ===\n（还没有收到过 payload）\n"
        } else {
            for item in input.telemetry {
                out += "\n=== 遥测：\(item.name) ===\n\(redact(item.text))\n"
            }
        }
        return out
    }
}

extension DiagnosticsBundle {

    /// 把「看起来像凭证」的片段换掉。
    ///
    /// 两条规则，都要求**足够长**才动手：短的值是普通单词（`token and ticket cleared`
    /// 里的 token 不是凭证），而凭证形态的东西至少 16 位。宁可漏一个短的，
    /// 也不要把正常日志改成读不懂的样子 —— 脱敏过度会让诊断包失去价值。
    static func redact(_ text: String) -> String {
        var out = text
        let rules: [(pattern: String, template: String)] = [
            ("Bearer\\s+[A-Za-z0-9._~+/=-]{16,}", "Bearer <redacted>"),
            ("(?i)(token|password|secret|key)\\s*[=:]\\s*[A-Za-z0-9._~+/=-]{16,}", "$1=<redacted>"),
        ]
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(
                in: out, range: range, withTemplate: rule.template
            )
        }
        return out
    }
}

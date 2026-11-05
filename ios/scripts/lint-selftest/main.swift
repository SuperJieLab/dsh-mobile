/**
 * 规则的自我核查：证明 `ios/.swiftlint.yml` 里那套正则还认得出正例、也没误伤反例。
 *
 * 为什么不用 SwiftLint 自己跑样本：样本要落在被扫描的树外，而 SwiftLint 的扫描面由配置的
 * `included` 决定 —— 让它扫临时目录要么改配置、要么复制一份，两样都比直接验正则脆。
 * 这里验的是**规则文本本身**（与 SwiftLint 同一个引擎：NSRegularExpression）；
 * 「SwiftLint 接得对不对」（match_kinds、only_rules 是否生效）由真实代码树上的违规数证明。
 */
import Foundation

// 三处相对位置都在 ios/ 下：本文件在 `ios/scripts/lint-selftest/`，上三级就是 ios/。
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func read(_ path: String) -> String {
    guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
        print("读不到 \(path)")
        exit(2)
    }
    return text
}

func parseRules(_ text: String) -> (rules: [String: String], only: [String], declared: [String]) {
    var rules: [String: String] = [:]
    var only: [String] = []
    var declared: [String] = []
    var inCustomRules = false
    var inOnlyRules = false
    var current: String?
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        if trimmed == "custom_rules:" {
            inCustomRules = true; inOnlyRules = false; current = nil; continue
        }
        if trimmed == "only_rules:" {
            inOnlyRules = true; inCustomRules = false; continue
        }
        if inOnlyRules, line.hasPrefix("  - ") {
            only.append(String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces))
            continue
        }
        guard inCustomRules else { continue }
        if line.hasPrefix("  "), !line.hasPrefix("    "), trimmed.hasSuffix(":") {
            current = String(trimmed.dropLast())
            declared.append(current!)
            continue
        }
        if trimmed.hasPrefix("regex: '"), let id = current {
            var pattern = String(trimmed.dropFirst("regex: '".count))
            if pattern.hasSuffix("'") { pattern.removeLast() }
            rules[id] = pattern
        }
    }
    return (rules, only, declared)
}

struct Sample {
    let expectHit: Bool
    let id: String
    let text: String
    let line: Int
}

func parseSamples(_ text: String) -> [Sample] {
    var samples: [Sample] = []
    for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = String(raw)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let parts = trimmed.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            print("样本第 \(index + 1) 行格式不对：\(trimmed)")
            exit(2)
        }
        guard let expectHit = ["expect-hit": true, "expect-pass": false][String(parts[0])] else {
            print("样本第 \(index + 1) 行不认识的前缀：\(parts[0])")
            exit(2)
        }
        samples.append(Sample(expectHit: expectHit,
                              id: String(parts[1]),
                              text: String(parts[2]),
                              line: index + 1))
    }
    return samples
}

let config = parseRules(read(iosRoot.appendingPathComponent(".swiftlint.yml").path))
let samples = parseSamples(read(iosRoot.appendingPathComponent("scripts/lint-selftest/samples.txt").path))

var failures: [String] = []

// 一、白名单必须启用「规则族」本身。SwiftLint 的白名单按规则族认：逐条列自定义规则的 id
// 不生效，而那种失效是静默的（0 违规全绿）。这一条把那个坑钉住。
if config.only != ["custom_rules"] {
    failures.append("only_rules 应当恰好是 [custom_rules]，实际是 \(config.only) —— 自定义规则不会生效")
}

// 二、规则 id 重复会被后一条静默覆盖（YAML 同键后写生效），规则数与声明数对不上即红。
if Set(config.declared).count != config.declared.count {
    failures.append("custom_rules 里有重复的规则 id：\(config.declared)")
}

// 三、每条规则都要有正例与反例；样本引用的 id 必须存在。
var hits: [String: Int] = [:]
var passes: [String: Int] = [:]
for sample in samples {
    hits[sample.id, default: 0] += sample.expectHit ? 1 : 0
    passes[sample.id, default: 0] += sample.expectHit ? 0 : 1
}
for id in config.rules.keys.sorted() {
    if hits[id, default: 0] == 0 { failures.append("规则 \(id) 没有 expect-hit 样本 —— 正则退化成永不命中时没人知道") }
    if passes[id, default: 0] == 0 { failures.append("规则 \(id) 没有 expect-pass 样本 —— 证明不了它不误伤") }
}
for id in Set(samples.map(\.id)) where config.rules[id] == nil {
    failures.append("样本引用了不存在的规则 \(id)")
}

// 四、逐条样本核对命中。
for sample in samples {
    guard let pattern = config.rules[sample.id] else { continue }
    let regex: NSRegularExpression
    do {
        regex = try NSRegularExpression(pattern: pattern)
    } catch {
        failures.append("规则 \(sample.id) 的正则编不过：\(pattern)")
        continue
    }
    let range = NSRange(sample.text.startIndex..., in: sample.text)
    let matched = regex.firstMatch(in: sample.text, range: range) != nil
    if sample.expectHit, !matched {
        failures.append("样本第 \(sample.line) 行应被 \(sample.id) 拦住，实际没命中：\(sample.text)")
    }
    if !sample.expectHit, matched {
        failures.append("样本第 \(sample.line) 行不该被 \(sample.id) 命中：\(sample.text)")
    }
}

if failures.isEmpty {
    print("PASS  规则 \(config.rules.count) 条 / 样本 \(samples.count) 条 / 失配 0")
    exit(0)
}
print("FAIL  规则 \(config.rules.count) 条 / 样本 \(samples.count) 条 / 失配 \(failures.count)")
for failure in failures { print("  · \(failure)") }
exit(1)

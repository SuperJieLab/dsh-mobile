/**
 * 七支契约测试共用的断言外壳：零第三方依赖、不 import SwiftUI / UIKit、不碰网络与磁盘；
 * 被 `run-*.sh` 的 `swiftc` 清单逐支编进去，所以每支仍可单独跑。
 * 计数与 `expect` 原本各文件各抄一遍，收尾汇总仍留在各文件（格式不同）。
 */
import Foundation

var passed = 0
var failed = 0

/// `label` 是判据编号 + 那句话，直接进 stdout。
func expect(_ ok: Bool, _ label: String) {
    if ok {
        passed += 1
        print("ok   \(label)")
    } else {
        failed += 1
        print("FAIL \(label)")
    }
}

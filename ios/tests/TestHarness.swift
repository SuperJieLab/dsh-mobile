/**
 * 七支契约测试共用的断言外壳。
 *
 * 与各测试同一手法：不 import SwiftUI / UIKit、零第三方依赖、不碰网络与磁盘 ——
 * 它只是被 `run-*.sh` 的 `swiftc` 清单逐支编进去，所以每支脚本仍可单独跑。
 *
 * 计数与 `expect` 原本在七份文件里各抄一遍；收尾的汇总仍留在各文件（各支的
 * 输出格式不同，且那是每支自己的事）。
 */
import Foundation

/// 通过的断言数。
var passed = 0
/// 失败的断言数。
var failed = 0

/// 记一条断言。`label` 是判据编号 + 那句话，直接进 stdout。
func expect(_ ok: Bool, _ label: String) {
    if ok {
        passed += 1
        print("ok   \(label)")
    } else {
        failed += 1
        print("FAIL \(label)")
    }
}

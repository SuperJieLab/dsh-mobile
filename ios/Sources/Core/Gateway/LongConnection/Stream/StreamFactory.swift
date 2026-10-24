/**
 * 业务侧能对这条连接做的唯一一件事：造一条流。
 *
 * 屏幕与 App 级订阅方拿到的都是它，而不是宿主的具体类型 —— 于是「一条流被拒时去关整条
 * 连接」写不出来：那个动作不在这个协议上，也不在任何流对象上。
 *
 * 关流与重开是流对象自己的方法（`LogicalStream.close()` / `restart()`），不在这里：
 * 造出来之后，谁持有它谁就能管它，不需要再回到宿主。
 */
import Foundation

@MainActor
protocol StreamFactory: AnyObject {

    /// 造一条流并登记。`nil` = 这一次开流放弃（开流文本编不出来）。
    ///
    /// **不幂等**：同一业务调两次就是两条流。业务要自己保证只造一次。
    func makeStream(_ behavior: any StreamBehavior) -> LogicalStream?
}

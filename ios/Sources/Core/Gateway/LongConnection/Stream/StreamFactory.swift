/**
 * 业务侧能对这条连接做的唯一一件事：造一条流。
 *
 * 屏幕与 App 级订阅方拿到的都是它，于是「一条流被拒时去关整条连接」写不出来。
 * 关流与重开是流对象自己的方法。
 */
import Foundation

@MainActor
protocol StreamFactory: AnyObject {

    /// 造一条流并登记。`nil` = 这一次开流放弃（开流文本编不出来）。
    ///
    /// **不幂等**：同一业务调两次就是两条流。业务要自己保证只造一次。
    func makeStream(_ behavior: any StreamBehavior) -> LogicalStream?
}

import SwiftUI

/// 动画规范。
///
/// iOS 原生的动效是「几乎察觉不到但很顺」：
/// 页面转场交给系统、sheet 交给系统、按钮只有亮度变化。
/// 这里只保留三档，且都不带弹跳。
enum DSMotion {
    /// 状态切换（开关、选中）
    static let quick = Animation.easeOut(duration: 0.16)
    /// 内容出现/消失
    static let standard = Animation.easeInOut(duration: 0.22)
    /// 数值变化（积分滚动）
    static let value = Animation.easeOut(duration: 0.3)
}

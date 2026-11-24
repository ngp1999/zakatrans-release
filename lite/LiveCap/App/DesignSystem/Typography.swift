import SwiftUI

/// 字体规范。
///
/// 一律用系统动态字体样式（Dynamic Type），不写死 points：
/// 用户在「设置 → 显示与亮度 → 文字大小」里调大，整个 App 跟着放大；
/// 中文字形由系统按字号自动挑选，不会出现「17pt + semibold 中文糊成一团」。
///
/// 只有两处例外，允许固定尺寸：
///   1. 字幕浮窗（用户自己调的字号，必须精确）
///   2. 画中画窗口（尺寸固定，跟着系统字号变会溢出）
enum DSFont {
    /// 页面大标题（很少用，iOS 里大标题只在根页面出现）
    static let largeTitle = Font.largeTitle.weight(.bold)
    /// 卡片/区块标题
    static let title2 = Font.title2.weight(.semibold)
    static let title3 = Font.title3.weight(.semibold)
    /// 列表行主文字、按钮文字
    static let headline = Font.headline
    static let body = Font.body
    /// 副标题、说明文字
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    /// 分组标题、辅助信息
    static let footnote = Font.footnote
    static let caption = Font.caption.weight(.regular)
    static let caption2 = Font.caption2
    /// 数字展示（等宽，避免跳动）
    static let number = Font.title2.weight(.semibold).monospacedDigit()
    static let numberLarge = Font.largeTitle.weight(.semibold).monospacedDigit()
}

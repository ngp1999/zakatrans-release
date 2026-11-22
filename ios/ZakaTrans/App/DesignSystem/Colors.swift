import SwiftUI

/// 颜色规范。
///
/// 全部走系统语义色：浅色/深色、提高对比度、灰度辅助功能都由系统负责，
/// 这里不写死任何一个 RGB（品牌强调色除外，它只用于强调，不做背景）。
enum DSColor {
    // MARK: 背景

    /// 普通页面底（内容页，如实时字幕工作区）
    static let background = Color(uiColor: .systemBackground)
    /// 分组列表页底（设置类页面，List/Form 的 insetGrouped 会自动用它）
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    /// 分组列表里的行底（系统设置页那种白块）
    static let cell = Color(uiColor: .secondarySystemGroupedBackground)
    /// 组内更深一档（开关关闭态、次要区块）
    static let cellAlt = Color(uiColor: .tertiarySystemGroupedBackground)
    /// 浮在内容上方的条（只有确实需要时才用，配合材质）
    static let barBackground = Color(uiColor: .systemBackground)

    // MARK: 文字

    static let label = Color(uiColor: .label)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
    static let tertiaryLabel = Color(uiColor: .tertiaryLabel)
    static let quaternaryLabel = Color(uiColor: .quaternaryLabel)
    /// 反色文字（填充按钮上）
    static let invertedLabel = Color(uiColor: .systemBackground)

    // MARK: 分隔与填充

    static let separator = Color(uiColor: .separator)
    static let opaqueSeparator = Color(uiColor: .opaqueSeparator)
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let fillSecondary = Color(uiColor: .secondarySystemFill)

    // MARK: 强调色

    /// 品牌强调色：只用于选中态、链接、主操作填充，不做大面积背景。
    static let accent = Color(red: 0.04, green: 0.58, blue: 0.53)
    /// 主操作填充用的品牌色（比 accent 略深，保证白字对比度达标）
    static let accentFill = Color(red: 0.03, green: 0.52, blue: 0.48)
    /// 强调色的浅底（选中行、标签底）
    static let accentSoft = Color(red: 0.04, green: 0.58, blue: 0.53).opacity(0.12)

    // MARK: 语义状态色

    static let destructive = Color(uiColor: .systemRed)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
}

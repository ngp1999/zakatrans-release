import SwiftUI

/// 间距规范。8pt 网格，全工程只用这几档，不随手写 13 / 18 / 22。
enum DSSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// 页面左右边距（iOS 原生列表页是 16）
    static let pageMargin: CGFloat = 16
    /// 内容区块之间的纵向间距
    static let sectionGap: CGFloat = 24
    /// 列表行的最小高度（系统默认 44）
    static let rowMinHeight: CGFloat = 44
}

/// 圆角规范。
///
/// 刻意收得很小：iOS 原生的圆角是有含义的——
/// 列表分组 10、按钮胶囊 12 / 全胶囊、sheet 20，不存在「所有东西都 20~24」。
enum DSRadius {
    /// 系统 inset grouped 列表的分组圆角
    static let card: CGFloat = 10
    /// 小控件（图标块、缩略图）
    static let small: CGFloat = 7
    /// 填充按钮
    static let button: CGFloat = 12
    /// sheet
    static let sheet: CGFloat = 20
}

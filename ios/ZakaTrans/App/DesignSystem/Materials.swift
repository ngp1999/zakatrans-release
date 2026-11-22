import SwiftUI

/// 材质规范。
///
/// 材质不是装饰，是层次：只有「浮在内容之上、需要透出底下」的东西才用。
/// 列表里的行不用材质——它们是页面内容本身，用系统分组底色即可。
enum DSMaterial {
    /// 导航栏 / 工具栏（交给系统，这里只做显式声明）
    static let bar: Material = .bar
    /// 浮在内容上的轻量控制条（字幕控制栏、播放控制）
    static let floating: Material = .ultraThinMaterial
    /// 弹出层底（sheet）
    static let sheet: Material = .regularMaterial
}

// MARK: - 版本兼容的玻璃层

/// 浮层的玻璃底。
///
/// iOS 26 上用官方的 Liquid Glass（`.glassEffect`），私钥式的高光、折射、边缘反光由系统算，
/// 比任何手绘描边+投影都准；iOS 16~18 退回系统材质 `.regularMaterial`，
/// 这也是 Apple 自己在那些版本上用的玻璃，观感天然一致。
///
/// 注意：绝大多数地方不需要手动调用它。TabView、导航栏、工具栏按钮、Sheet、List
/// 在 iOS 26 上会**自动**变成新的液态玻璃外观——用系统控件就等于拿到了，不用自己再涂一层。
/// 手写玻璃只留给真正自定义的浮层（字幕控制条这类）。
struct GlassCompat: ViewModifier {
    var radius: CGFloat = DSRadius.card
    var material: Material = DSMaterial.floating

    func body(content: Content) -> some View {
        content.dsGlassBackground(radius: radius, material: material)
    }
}

extension View {
    @ViewBuilder
    func dsGlassBackground(radius: CGFloat, material: Material) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(material, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension View {
    /// 浮层的玻璃底。只在真正需要「透出底下内容」的地方用。
    func dsGlass(radius: CGFloat = DSRadius.card,
                 material: Material = DSMaterial.floating) -> some View {
        modifier(GlassCompat(radius: radius, material: material))
    }
}

// MARK: - 系统卡片（非材质）

/// 系统分组列表那种「白块」：实色 `secondarySystemGroupedBackground` + 10pt 圆角。
/// 没有描边、没有投影、没有渐变——iOS 原生的内容块就是这样。
struct SystemCard: ViewModifier {
    var padding: CGFloat = DSSpace.m
    var radius: CGFloat = DSRadius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.cell, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func systemCard(padding: CGFloat = DSSpace.m, radius: CGFloat = DSRadius.card) -> some View {
        modifier(SystemCard(padding: padding, radius: radius))
    }
}

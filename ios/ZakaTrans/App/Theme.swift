import SwiftUI
import UIKit

/// 视觉基调：原生 iOS 的层叠观感。
///
/// 上一版是「系统语义色 + 平铺卡片」——干净，但整屏纯白、卡片是实色填充，
/// 除了积分胶囊之外没有一处材质，看上去像系统设置页，没有 iOS 那种质感。
///
/// 这一版把层次补齐，分三层：
///   1. 底：一层极淡的环境色晕（青绿 + 一点靛蓝、暖橙），深浅色各一套，永远在内容后面
///   2. 面：卡片/面板一律用系统材质（.thinMaterial / .ultraThinMaterial），
///      底下的色晕透上来，才是「毛玻璃」而不是「灰方块」
///   3. 边：1px 的顶亮底暗描边 + 极浅投影，模拟玻璃的厚度
///
/// 全部用系统材质和语义色，深色模式自动跟随，不自己调夜景色板。
enum Theme {
    // 品牌色：唯一强调色
    static let accent = Color(red: 0.06, green: 0.62, blue: 0.56)
    /// 主按钮渐变的下端，比 accent 深一档，撑出体积
    static let accentDeep = Color(red: 0.02, green: 0.46, blue: 0.45)
    static let accentSoft = Color(red: 0.06, green: 0.62, blue: 0.56).opacity(0.12)

    // 系统语义色：深色模式自动适配
    static let bg = Color(uiColor: .systemBackground)
    static let bgElevated = Color(uiColor: .systemBackground)
    /// 仍保留实色版本：少量地方（画中画取色、遮罩）需要不透明底
    static let card = Color(uiColor: .secondarySystemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let surfaceDeep = Color(uiColor: .tertiarySystemFill)
    static let hairline = Color(uiColor: .separator).opacity(0.45)
    static let ink = Color(uiColor: .label)
    static let sub = Color(uiColor: .secondaryLabel)
    static let faint = Color(uiColor: .tertiaryLabel)
    static let line = Color(uiColor: .separator).opacity(0.7)
    static let fill = Color(uiColor: .tertiarySystemFill)

    static let warn = Color(uiColor: .systemRed)
    static let ok = Color(uiColor: .systemGreen)

    static let radius: CGFloat = 20
    static let radiusLarge: CGFloat = 26
    static let radiusSmall: CGFloat = 14
}

// MARK: - 环境底色

/// 铺在最底下的一层：系统底色 + 三团极淡的色晕。
///
/// 它的作用不是「好看」，是让上层的材质有东西可透——底下是纯白的话，
/// 毛玻璃和实色填充在屏幕上没有区别，这就是上一版看不出材质的原因。
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            let h = max(g.size.height, 1)
            let dark = scheme == .dark

            ZStack {
                Theme.bg

                // 左上：品牌青绿，主光
                Circle()
                    .fill(Theme.accent.opacity(dark ? 0.34 : 0.17))
                    .frame(width: w * 0.95, height: w * 0.95)
                    .blur(radius: 120)
                    .offset(x: -w * 0.34, y: -h * 0.34)

                // 右上偏下：靛蓝，冷色对比
                Circle()
                    .fill(Color(red: 0.32, green: 0.44, blue: 0.98).opacity(dark ? 0.26 : 0.11))
                    .frame(width: w * 1.05, height: w * 1.05)
                    .blur(radius: 140)
                    .offset(x: w * 0.42, y: -h * 0.02)

                // 底部：一点暖色，避免整体发青
                Circle()
                    .fill(Color(red: 0.99, green: 0.74, blue: 0.45).opacity(dark ? 0.12 : 0.10))
                    .frame(width: w * 0.9, height: w * 0.9)
                    .blur(radius: 150)
                    .offset(x: w * 0.12, y: h * 0.44)

                // 顶部一层很轻的高光，像系统壁纸的光照方向
                LinearGradient(
                    colors: [
                        Color.white.opacity(dark ? 0.05 : 0.38),
                        Color.white.opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension View {
    /// 整屏底色。所有页面统一用它，别再用 `.background(Theme.bg)`
    func screenBackground() -> some View { background(AmbientBackground()) }
}

// MARK: - 材质面

/// 玻璃面：系统材质 + 顶亮底暗的 1px 描边 + 极浅投影。
/// `material` 越薄透得越多：浮在内容上方的条用 .ultraThinMaterial，成块的卡片用 .thinMaterial。
struct GlassSurface: ViewModifier {
    var radius: CGFloat = Theme.radius
    var material: Material = .thinMaterial
    var elevated: Bool = true

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(material, in: shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(scheme == .dark ? 0.22 : 0.60),
                            Color.white.opacity(scheme == .dark ? 0.04 : 0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .overlay(
                shape.strokeBorder(Color.black.opacity(scheme == .dark ? 0.30 : 0.05), lineWidth: 0.5)
            )
            .shadow(
                color: Color.black.opacity(elevated ? (scheme == .dark ? 0.38 : 0.07) : 0),
                radius: elevated ? 22 : 0,
                x: 0,
                y: elevated ? 10 : 0
            )
    }
}

extension View {
    func glassSurface(radius: CGFloat = Theme.radius,
                      material: Material = .thinMaterial,
                      elevated: Bool = true) -> some View {
        modifier(GlassSurface(radius: radius, material: material, elevated: elevated))
    }
}

// MARK: - 卡片

/// 卡片：一块材质面 + 大圆角。
/// 跟上一版相比只换了「底」——原来是实色填充，现在是材质，透出底下的环境色。
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = Theme.radius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(radius: radius)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }
}

// MARK: - 玻璃胶囊（浮条、胶囊按钮）

/// 悬浮在内容之上的胶囊/按钮用这个。
struct GlassBackground: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content.glassSurface(radius: radius, material: .ultraThinMaterial)
    }
}

extension View {
    func glass(radius: CGFloat = 22) -> some View { modifier(GlassBackground(radius: radius)) }
}

// MARK: - 按钮

/// 主按钮：品牌色渐变 + 顶部一道高光 + 同色投影，圆角胶囊。
/// 原先是纯色方块，按下只缩放；现在多了体积和光，跟系统的「填充按钮」是一个观感。
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Theme.sub)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                shape
                    .fill(enabled ? tint : Theme.fill)
                    .overlay {
                        if enabled {
                            shape.fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.26), Color.white.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        }
                    }
            }
            .overlay(
                shape.strokeBorder(
                    Color.white.opacity(enabled ? 0.30 : 0.10),
                    lineWidth: 1
                )
            )
            .shadow(
                color: enabled ? tint.opacity(configuration.isPressed ? 0.18 : 0.34) : .clear,
                radius: configuration.isPressed ? 8 : 18,
                x: 0,
                y: configuration.isPressed ? 4 : 9
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// 次按钮：材质底，无描边（原生 App 里第二层级按钮就是这种）
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .glassSurface(radius: 16, material: .ultraThinMaterial, elevated: false)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// 列表行按钮：点在整行上，右侧有箭头
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Theme.fill : Color.clear)
    }
}

// MARK: - 小部件

/// 顶部右侧的积分胶囊
struct CreditPill: View {
    var credits: Double
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(Format.credits(credits))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glass(radius: 18)
        }
        .buttonStyle(.plain)
    }
}

/// 分组标题（小字，灰色），原生设置页的样子
struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Theme.sub)
            .textCase(nil)
            .padding(.leading, 4)
    }
}

/// 带图标的设置行
struct SettingRow<Trailing: View>: View {
    var icon: String
    var title: String
    var tint: Color = Theme.accent
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 分段控件

/// 系统观感的分段控件：材质轨道 + 一块浮起来的白色滑块，切换时滑块滑过去。
/// 没用 SwiftUI 自带的 .pickerStyle(.segmented)，因为它的轨道是固定灰、在材质底上很突兀，
/// 也调不了圆角和高度；这里按系统那套自己画，颜色一律走材质和系统语义色。
struct GlassSegmented<T: Hashable>: View {
    var items: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 40

    @Namespace private var thumb
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                let active = item.0 == selection
                Button {
                    guard !active else { return }
                    Haptics.tap()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = item.0
                    }
                } label: {
                    Text(item.1)
                        .font(.system(size: 15, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Theme.ink : Theme.sub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: height - 8)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: (height - 8) / 2, style: .continuous)
                                    .fill(scheme == .dark
                                          ? AnyShapeStyle(Color.white.opacity(0.14))
                                          : AnyShapeStyle(Color(uiColor: .systemBackground)))
                                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.10),
                                            radius: 5, x: 0, y: 2)
                                    .matchedGeometryEffect(id: "segThumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(height: height)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.18 : 0.55),
                                 Color.white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
        )
    }
}

// MARK: - Sheet 外观

/// 统一的 sheet 外观：圆角、顶部指示条、毛玻璃底。
/// presentationCornerRadius / presentationBackground 是 16.4 才有的，低版本只加指示条。
struct SheetChrome: ViewModifier {
    var radius: CGFloat = 28

    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(radius)
                .presentationBackground(.regularMaterial)
        } else {
            content.presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func sheetChrome(radius: CGFloat = 28) -> some View { modifier(SheetChrome(radius: radius)) }

    /// 导航栏用材质底，滚动时跟内容之间有一层玻璃，不是一块死白
    func glassNavigationBar() -> some View {
        self
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - 格式化

enum Format {
    /// 积分显示：整数不显示小数，有小数保留两位
    static func credits(_ v: Double) -> String {
        if abs(v.rounded() - v) < 0.005 {
            return "\(Int(v.rounded()))"
        }
        return String(format: "%.2f", v)
    }

    static func duration(_ ms: Int64) -> String {
        let s = max(0, ms) / 1000
        if s < 60 { return "\(s) 秒" }
        let m = s / 60, r = s % 60
        if m < 60 { return r == 0 ? "\(m) 分钟" : "\(m) 分 \(r) 秒" }
        let h = m / 60
        return "\(h) 小时 \(m % 60) 分"
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(d) { f.dateFormat = "今天 HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = "昨天 HH:mm" }
        else if cal.component(.year, from: d) == cal.component(.year, from: Date()) { f.dateFormat = "M月d日 HH:mm" }
        else { f.dateFormat = "yyyy年M月d日 HH:mm" }
        return f.string(from: d)
    }
}

// MARK: - 提示弹窗（自绘）

/// 统一的提示框：材质卡、圆角、一枚主题色按钮，跟 App 其他地方是同一套语言。
struct NoticeDialog: View {
    let title: String
    let message: String
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)

                ScrollView(showsIndicators: false) {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.sub)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 220)

                Button {
                    Haptics.tap()
                    onClose()
                } label: {
                    Text("知道了")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(TileButtonStyle())
            }
            .padding(20)
            .frame(maxWidth: 330)
            .glassSurface(radius: 24, material: .regularMaterial)
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
    }
}

extension View {
    /// 用法：`.notice($errorText)`，把一条可选文案当成弹窗内容，置 nil 即关闭。
    func notice(_ message: Binding<String?>, title: String = "提示") -> some View {
        overlay {
            if let m = message.wrappedValue, !m.isEmpty {
                NoticeDialog(title: title, message: m) {
                    message.wrappedValue = nil
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: message.wrappedValue)
    }
}

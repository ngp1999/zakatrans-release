import SwiftUI
import UIKit

/// 视觉基调：Apple 原生。
///
/// 这里只放**兼容层**：老的调用点（`glassSurface` / `.card()` / `screenBackground()` …）
/// 全部保留原名，但实现已经换成系统原生的东西。
///
/// 具体改了什么（对比上一版）：
///   · 删掉整屏彩色色晕 —— iOS 原生页面不会在内容底下铺三团 blur 圆，那是网页 glassmorphism 的做法
///   · 删掉卡片描边 + 投影 —— 原生内容块就是一块实色，层次靠分组、留白、分隔线，不靠影子
///   · 删掉主按钮的渐变 + 高光 + 同色投影 —— 原生填充按钮就是一层实色
///   · 分段控件换成系统 `Picker(.segmented)`
///   · 导航栏不再手动塞材质，交回系统
///
/// 新代码请直接用 `DSColor` / `DSFont` / `DSSpace` / `DSRadius` / `DSGroup` / `DSRow`，
/// 不要再用这里的 `glassSurface` 之类的过渡 API。
enum Theme {
    // 强调色
    static let accent = DSColor.accent
    static let accentDeep = DSColor.accentFill
    static let accentSoft = DSColor.accentSoft

    // 背景（语义色，深浅色自动）
    static let bg = DSColor.background
    static let bgElevated = DSColor.background
    static let card = DSColor.cell
    static let surface = DSColor.cell
    static let surfaceDeep = DSColor.cellAlt
    static let hairline = DSColor.separator
    static let line = DSColor.separator

    // 文字
    static let ink = DSColor.label
    static let sub = DSColor.secondaryLabel
    static let faint = DSColor.tertiaryLabel
    static let fill = DSColor.fill

    // 状态
    static let warn = DSColor.destructive
    static let ok = DSColor.success

    // 圆角：收小到系统规格
    static let radius: CGFloat = DSRadius.card
    static let radiusLarge: CGFloat = DSRadius.sheet
    static let radiusSmall: CGFloat = DSRadius.small
}

// MARK: - 页面底色

/// 页面底。以前是「系统底色 + 三团彩色 blur」，现在是系统分组背景色。
/// 它是 `List` / `Form` 的标配底色，跟系统设置页完全一致，深浅色自动。
struct AmbientBackground: View {
    var body: some View {
        DSColor.groupedBackground.ignoresSafeArea()
    }
}

extension View {
    /// 整屏底色。设置类页面统一用它；用 `List`/`Form` 的页面不需要，系统自带。
    func screenBackground() -> some View {
        background(DSColor.groupedBackground.ignoresSafeArea())
    }
}

// MARK: - 内容块

/// 兼容老调用的内容块：系统卡片（实色 + 10pt 圆角），无描边、无投影、无材质。
///
/// `material` / `elevated` 两个参数保留只为不改调用点，实际不再生效——
/// 内容块不该是玻璃，玻璃只留给真正浮在内容之上的东西（导航栏、控制条）。
struct GlassSurface: ViewModifier {
    var radius: CGFloat = DSRadius.card
    var material: Material = .thinMaterial
    var elevated: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                DSColor.cell,
                in: RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
            )
    }
}

extension View {
    func glassSurface(radius: CGFloat = DSRadius.card,
                      material: Material = .thinMaterial,
                      elevated: Bool = true) -> some View {
        modifier(GlassSurface(radius: radius, material: material, elevated: elevated))
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = DSSpace.m
    var radius: CGFloat = DSRadius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.cell, in: RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = DSSpace.m) -> some View { modifier(CardBackground(padding: padding)) }
}

// MARK: - 浮层

/// 真正浮在内容之上、需要透出底下的东西才用它（字幕控制条之类）。
/// iOS 26 上是官方 Liquid Glass，更低的系统退回系统材质，都不自绘描边和投影。
struct GlassBackground: ViewModifier {
    var radius: CGFloat = DSRadius.card
    func body(content: Content) -> some View {
        content.dsGlass(radius: radius, material: DSMaterial.floating)
    }
}

extension View {
    func glass(radius: CGFloat = DSRadius.card) -> some View { modifier(GlassBackground(radius: radius)) }
}

// MARK: - 按钮

/// 主操作按钮（兼容老调用）。实现同 `DSFilledButtonStyle`：
/// 实色底、白字、12pt 圆角，按下只变亮度，没有渐变/高光/投影。
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    var tint: Color = DSColor.accentFill

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSFont.headline)
            .foregroundStyle(enabled ? Color.white : DSColor.tertiaryLabel)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background(
                enabled ? tint : DSColor.fill,
                in: RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(nil, value: configuration.isPressed)
    }
}

/// 次按钮（兼容老调用）
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = DSColor.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSFont.callout.weight(.medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(DSColor.fill, in: RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(nil, value: configuration.isPressed)
    }
}

/// 列表行按压反馈（兼容老调用）
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? DSColor.fill : Color.clear)
    }
}

// MARK: - 小部件

/// 顶部积分胶囊。
/// 原生 App 里这种「数值 + 图标」的胶囊就是一个浅灰底，不用玻璃——
/// 玻璃在纯色背景上透不出东西，只会显得脏。
struct CreditPill: View {
    var credits: Double
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: DSSpace.xxs + 1) {
                Image(systemName: "bolt.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DSColor.accent)
                Text(Format.credits(credits))
                    .font(DSFont.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DSColor.label)
            }
            .padding(.horizontal, DSSpace.s)
            .padding(.vertical, 6)
            .background(DSColor.fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 分组标题
struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DSFont.footnote)
            .foregroundStyle(DSColor.secondaryLabel)
            .textCase(nil)
            .padding(.leading, DSSpace.xxs)
    }
}

/// 带图标的设置行
struct SettingRow<Trailing: View>: View {
    var icon: String
    var title: String
    var tint: Color = DSColor.accent
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DSSpace.s) {
            DSIconTile(systemName: icon, tint: tint)
            Text(title)
                .font(DSFont.body)
                .foregroundStyle(DSColor.label)
            Spacer(minLength: DSSpace.xs)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 分段控件

/// 分段控件。内部直接用系统 `Picker(.segmented)`：
/// 轨道色、滑块阴影、切换动画、深浅色、动态字体、VoiceOver 全部由系统负责，
/// 不使用自绘实现——自绘的版本在任何系统版本上都和周围控件对不齐。
struct GlassSegmented<T: Hashable>: View {
    var items: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 32

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(items, id: \.0) { item in
                Text(item.1).tag(item.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Sheet / 导航栏

/// sheet 外观：交回系统。
/// 系统 sheet 自带圆角、带回弹的下拉关闭、自带的材质层次；
/// 手动指定 `presentationBackground(.regularMaterial)` 会和系统导航栏、滚动边缘撞在一起，显得脏。
struct SheetChrome: ViewModifier {
    var radius: CGFloat = DSRadius.sheet

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

extension View {
    func sheetChrome(radius: CGFloat = DSRadius.sheet) -> some View { modifier(SheetChrome(radius: radius)) }

    /// 导航栏：不给任何自定义背景。
    /// 系统会在滚动时自己把导航栏变成带材质的悬浮层，手动指定反而会锁死它。
    func glassNavigationBar() -> some View { self }
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

// MARK: - 提示弹窗

/// 提示框：按系统 alert 的规格来——居中、14pt 圆角、系统材质底、标题 + 正文 + 一枚确认按钮。
/// 系统 alert 也是带材质的，这里用的是系统规格而不是自造的玻璃卡。
struct NoticeDialog: View {
    let title: String
    let message: String
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: DSSpace.m) {
                VStack(spacing: DSSpace.xs - 2) {
                    Text(title)
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.label)

                    ScrollView(showsIndicators: false) {
                        Text(message)
                            .font(DSFont.footnote)
                            .foregroundStyle(DSColor.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 200)
                }

                Divider()

                Button("好") {
                    Haptics.tap()
                    onClose()
                }
                .font(DSFont.body)
                .buttonStyle(.plain)
                .foregroundStyle(DSColor.accent)
            }
            .padding(.horizontal, DSSpace.m)
            .padding(.vertical, DSSpace.m)
            .frame(maxWidth: 270)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .animation(DSMotion.quick, value: message.wrappedValue)
    }
}

import SwiftUI
import UIKit

/// 视觉基调：原生 iOS 观感。
///
/// 参考 ChatGPT / Gemini 那类 App 的做法——不自己造色板，
/// 背景、卡片、分隔线全部用系统语义色，深浅色模式自动跟随；
/// 强调色只用一个（青绿），警示才用红。
///
/// 「Liquid Glass」在 iOS 26 是系统材质，iOS 16 上没法直接调那个 API，
/// 这里用 `.ultraThinMaterial` + 一层极细高光描边 + 柔和投影做等效观感，
/// 在 16 上看起来是同一类东西，不会像自制渐变那样「一眼 DIY」。
enum Theme {
    // 品牌色：唯一强调色
    static let accent = Color(red: 0.06, green: 0.62, blue: 0.56)
    static let accentSoft = Color(red: 0.06, green: 0.62, blue: 0.56).opacity(0.10)

    // 系统语义色：深色模式自动适配。
    // 底色用纯白/纯黑的 systemBackground，分组面用 secondarySystemBackground，
    // 层次靠一块淡淡的填充 + 一根极细的分隔线，不靠投影——这样看起来像成品工具，不像模板。
    static let bg = Color(uiColor: .systemBackground)
    static let bgElevated = Color(uiColor: .systemBackground)
    static let card = Color(uiColor: .secondarySystemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let surfaceDeep = Color(uiColor: .tertiarySystemFill)
    static let hairline = Color(uiColor: .separator).opacity(0.5)
    static let ink = Color(uiColor: .label)
    static let sub = Color(uiColor: .secondaryLabel)
    static let faint = Color(uiColor: .tertiaryLabel)
    static let line = Color(uiColor: .separator)
    static let fill = Color(uiColor: .tertiarySystemFill)

    static let warn = Color(uiColor: .systemRed)
    static let ok = Color(uiColor: .systemGreen)

    static let radius: CGFloat = 16
    static let radiusSmall: CGFloat = 12
}

// MARK: - 卡片

/// 系统风格的卡片：一块比背景略亮的填充 + 大圆角，没有描边、没有阴影。
/// 这是 iOS「设置」「健康」那种原生分组的样子。
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }
}

// MARK: - 玻璃（iOS 16 等效实现）

/// 悬浮在内容之上的胶囊/按钮用这个。
/// 真机上是毛玻璃，iOS 16 上也是真材质，不是画出来的假透明。
struct GlassBackground: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func glass(radius: CGFloat = 22) -> some View { modifier(GlassBackground(radius: radius)) }
}

// MARK: - 按钮

/// 主按钮：实心强调色，圆角 16，按下轻微缩放。
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(enabled ? tint : Theme.fill)
            .foregroundStyle(enabled ? Color.white : Theme.sub)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 次按钮：浅填充，无描边（原生 App 里第二层级按钮就是这种）
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.65 : 1)
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

/// 分组标题（大写小字，灰色），原生设置页的样子
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

/// 统一的提示框：白卡、圆角、一枚主题色按钮，跟协议弹窗是同一套语言。
/// 系统 alert 是灰底方框、字号和控制都不好调，一弹出来就跟 App 其他地方不是一套东西；
/// 这个自己画，深浅色、圆角、字重都跟页面一致。
struct NoticeDialog: View {
    let title: String
    let message: String
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
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
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.18), radius: 26, y: 10)
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

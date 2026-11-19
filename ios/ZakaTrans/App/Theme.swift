import SwiftUI

/// 视觉基调：白底、极简、留白多，状态色只用一个青，警示用低饱和红。
/// 不用图片素材，全部是系统控件和材质。
enum Theme {
    static let bg = Color(white: 0.98)
    static let card = Color.white
    static let ink = Color(white: 0.09)
    static let sub = Color(white: 0.45)
    static let line = Color(white: 0.90)
    static let accent = Color(red: 0.05, green: 0.62, blue: 0.60)
    static let warn = Color(red: 0.78, green: 0.24, blue: 0.24)

    static let radius: CGFloat = 18
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.line, lineWidth: 0.5)
            )
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardBackground(padding: padding)) }
}

/// 主按钮：白底黑字，按下有轻微缩放，不用花哨渐变
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Theme.sub)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(enabled ? Theme.ink : Color(white: 0.93))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.line, lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

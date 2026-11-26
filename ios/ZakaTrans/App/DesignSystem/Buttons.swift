import SwiftUI

// MARK: - 主操作按钮

/// 主操作按钮（「开启实时字幕」「支付」这类整页唯一的主操作）。
///
/// 观感对齐系统 `.borderedProminent`：实色品牌底、白字、12pt 圆角，
/// 按下只有系统式的亮度变化，没有缩放、没有渐变、没有投影。
/// 之所以不用直接用 `.borderedProminent`，是因为它取的是全局 tint，
/// 停止态要变红时需要单独切换 tint；样式本身保持一致。
struct DSFilledButtonStyle: ButtonStyle {
    var tint: Color = DSColor.accentFill
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSFont.headline)
            .foregroundStyle(enabled ? Color.white : DSColor.tertiaryLabel)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .background(
                (enabled ? tint : DSColor.fill),
                in: RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(nil, value: configuration.isPressed)
    }
}

// MARK: - 次要按钮

/// 次要按钮（同一屏里的第二个操作）。
/// 对齐系统 `.bordered`：浅填充底、无边框线、强调色文字。
struct DSBorderedButtonStyle: ButtonStyle {
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

// MARK: - 行按压反馈

/// 列表行的按压反馈：按下整行变浅灰，跟系统设置页一致（不做缩放、不做回弹）
struct DSRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? DSColor.fill : Color.clear)
    }
}

// MARK: - 图标按钮

/// 圆形图标按钮（字幕页的辅助控制）。
/// 系统 `.bordered` 的圆形变体：浅填充底 + 强调色图标，没有描边和投影。
struct DSIconButtonStyle: ButtonStyle {
    var on: Bool = false
    var size: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(on ? Color.white : DSColor.label)
            .frame(width: size, height: size)
            .background(
                on ? DSColor.accentFill : DSColor.fill,
                in: Circle()
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(nil, value: configuration.isPressed)
    }
}

// MARK: - 首页主按钮（主题色渐变 + 玻璃高光）

/// 首页那颗「开启实时字幕」的主按钮。
///
/// 用玻璃质感是为了让它看着像一颗真按钮、有按下去的欲望：
/// 底层是主题色渐变（不透明，保证白字始终够清楚），上面叠一层从顶到底的高光，
/// 边框再走一圈半透明白描边，按下时整体轻微收缩、投影收紧。
struct DSGlassPrimaryButtonStyle: ButtonStyle {
    var tint: Color = DSColor.accentFill
    var deep: Color = DSColor.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSFont.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                        .fill(tint)
                    RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [deep.opacity(0.95), tint.opacity(0.62)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.28), Color.white.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: deep.opacity(configuration.isPressed ? 0.18 : 0.36),
                    radius: configuration.isPressed ? 5 : 14,
                    y: configuration.isPressed ? 1 : 7)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

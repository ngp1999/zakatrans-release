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
/// 跟主按钮同一套系统玻璃：iOS 26 原生 Liquid Glass，低版本系统毛玻璃，
/// 不铺主题色底，图标走主题色。
struct DSIconButtonStyle: ButtonStyle {
    var on: Bool = false
    var size: CGFloat = 50

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(on ? DSColor.accentFill : DSColor.accent)
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: Circle())
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        } else {
            configuration.label
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(on ? DSColor.accentFill : DSColor.accent)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .opacity(configuration.isPressed ? 0.75 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

// MARK: - 首页主按钮（系统玻璃材质）

/// 首页那颗「开启实时字幕」的主按钮。
///
/// 用的是**系统自己的玻璃**，不是自己拼的渐变，也不铺任何主题色底：
///   · iOS 26 及以上 → 原生 Liquid Glass（`.glassEffect`），跟系统按钮同一套折射与高光
///   · iOS 26 以下 → 系统 `ultraThinMaterial` 毛玻璃
/// 底色完全交给系统材质，只有文字是主题色（停止态红色）。
struct DSGlassPrimaryButtonStyle: ButtonStyle {
    /// 仅作兼容保留，不参与绘制
    var tint: Color = DSColor.accentFill
    /// 文字色（停止态传红色）
    var deep: Color = DSColor.accent

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)

        if #available(iOS 26.0, *) {
            configuration.label
                .font(DSFont.headline)
                .foregroundStyle(deep)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .glassEffect(.regular.interactive(), in: shape)
                .opacity(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        } else {
            configuration.label
                .font(DSFont.headline)
                .foregroundStyle(deep)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .background(.ultraThinMaterial, in: shape)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

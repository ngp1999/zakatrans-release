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

// MARK: - 首页主按钮（系统玻璃材质）

/// 首页那颗「开启实时字幕」的主按钮。
///
/// 用的是**系统自己的玻璃**，不是自己拼的渐变：
///   · iOS 26 及以上 → 原生 Liquid Glass（`.glassEffect`），跟系统按钮同一套折射与高光
///   · iOS 26 以下 → 系统 `ultraThinMaterial` 毛玻璃，底下垫一层很淡的主题色
/// 两种都是半透明、看得见底下内容的材质，文字走主题色，不铺实色底、不画渐变。
struct DSGlassPrimaryButtonStyle: ButtonStyle {
    /// 文字与淡色底用的主题色
    var tint: Color = DSColor.accentFill
    /// 停止态换成红色时用同一套材质
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
                .glassEffect(.regular.tint(deep.opacity(0.16)).interactive(), in: shape)
                .opacity(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        } else {
            configuration.label
                .font(DSFont.headline)
                .foregroundStyle(deep)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
                .background(deep.opacity(0.08), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(DSColor.separator, lineWidth: 0.5))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

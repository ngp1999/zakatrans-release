import SwiftUI

// MARK: - 分组

/// 系统设置页那种分组容器：白色块、10pt 圆角、行与行之间一条 0.5pt 分隔线。
/// 分隔线从文字左边开始（跟系统一致），不是通栏。
struct DSGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(DSColor.cell, in: RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
    }
}

/// 分组标题：小字、次级色、左边距跟内容对齐。
struct DSSectionHeader: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DSFont.footnote)
            .foregroundStyle(DSColor.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSSpace.m)
            .padding(.bottom, DSSpace.xs - 2)
    }
}

/// 分组内的一行。
struct DSRow<Trailing: View>: View {
    var icon: String?
    var iconTint: Color = DSColor.accent
    var title: String
    var subtitle: String?
    var showsChevron: Bool = false
    var destructive: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DSSpace.s) {
            if let icon {
                DSIconTile(systemName: icon, tint: destructive ? DSColor.destructive : iconTint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DSFont.body)
                    .foregroundStyle(destructive ? DSColor.destructive : DSColor.label)
                if let subtitle {
                    Text(subtitle)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.secondaryLabel)
                }
            }
            Spacer(minLength: DSSpace.xs)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DSColor.tertiaryLabel)
            }
        }
        .padding(.horizontal, DSSpace.m)
        .frame(minHeight: DSSpace.rowMinHeight)
        .contentShape(Rectangle())
    }
}

extension DSRow where Trailing == EmptyView {
    init(icon: String? = nil,
         iconTint: Color = DSColor.accent,
         title: String,
         subtitle: String? = nil,
         showsChevron: Bool = false,
         destructive: Bool = false) {
        self.init(icon: icon, iconTint: iconTint, title: title, subtitle: subtitle,
                  showsChevron: showsChevron, destructive: destructive) { EmptyView() }
    }
}

/// 设置页那种圆角方形图标（28×28，白图标，彩色底）。系统设置、App Store 都是这个规格。
struct DSIconTile: View {
    var systemName: String
    var tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint, in: RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous))
    }
}

/// 组内分隔线：从文字起点开始，跟系统一致。
struct DSDivider: View {
    var leading: CGFloat = DSSpace.m + 28 + DSSpace.s
    var body: some View {
        Rectangle()
            .fill(DSColor.separator)
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}

// MARK: - 空状态

/// 空状态：一个系统符号 + 一句说明。不做插画、不做彩色渐变。
struct DSEmptyState: View {
    var icon: String
    var title: String
    var message: String?

    var body: some View {
        VStack(spacing: DSSpace.s) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DSColor.tertiaryLabel)
            Text(title)
                .font(DSFont.headline)
                .foregroundStyle(DSColor.secondaryLabel)
            if let message {
                Text(message)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.tertiaryLabel)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpace.xxl)
    }
}

import SwiftUI

/// 面板里的滚动区：内容比上限矮就按内容高度撑，底部不留空白；
/// 内容比上限高才滚动。以前一律写死 frame(height:)，内容少的时候
/// 面板底部就是一大片空的，和屏幕底边之间也留着一道缝。
struct FitScroll<Content: View>: View {
    let cap: CGFloat
    private let content: Content
    @State private var contentH: CGFloat = 0

    init(cap: CGFloat, @ViewBuilder content: () -> Content) {
        self.cap = cap
        self.content = content()
    }

    private var height: CGFloat {
        if contentH < 1 { return cap }        // 第一次布局还不知道内容多高，先按上限占位
        return min(contentH, cap)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            content
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: PanelContentHeight.self, value: g.size.height)
                    }
                )
        }
        .frame(height: height)
        // 第一次量出来的高度比上限矮时，面板跟着收一下；带一点动画，
        // 不然「先按满高弹出来、再瞬间缩一刀」，看着像闪了一下。
        .animation(.spring(response: 0.30, dampingFraction: 0.92), value: height)
        .onPreferenceChange(PanelContentHeight.self) { v in
            if abs(v - contentH) > 0.5 { contentH = v }
        }
    }
}

private struct PanelContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// 面板背景：只圆上面两个角，一路铺到屏幕物理底边（底下不留缝）
    func panelBackground(_ color: Color) -> some View {
        self.background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                .fill(color)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// 当前窗口的安全区底部高度（有 Home 指示条的机型是 34）
enum SafeArea {
    static var bottom: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets.bottom ?? 0
    }
}

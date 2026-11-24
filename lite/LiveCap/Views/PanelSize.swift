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
        // 第一帧还没量出内容高度时整块先藏起来：
        // 以前是先按上限铺满、量完再收回真实高度，中间那一下就是用户看到的
        // 「突然多出一大块空白，然后又缩回去」。藏一帧比闪一下强。
        .opacity(contentH < 1 ? 0 : 1)
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

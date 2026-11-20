import SwiftUI

/// 入口：启动图 → 没登录就是登录页，登录后进主界面。
struct RootView: View {
    @ObservedObject private var cloud = Cloud.shared
    @State private var splash = true

    var body: some View {
        ZStack {
            if cloud.loggedIn {
                MainView()
                    .transition(.opacity)
            } else {
                LoginView()
                    .transition(.opacity)
            }

            if splash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: cloud.loggedIn)
        .task {
            // 冷启动：本地有登录态就立刻放行，不等网络。
            await cloud.bootstrap()
            // 启动图只做一次很短的过渡，不做长时间停留
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeOut(duration: 0.22)) { splash = false }

            // 下面这些都在界面出来之后才跑，谁也不挡启动
            Task {
                if cloud.loggedIn {
                    await AppState.shared.syncPrefsFromCloud()
                }
                await Purchases.shared.load()
                await Purchases.shared.syncUnfinished()
            }
        }
    }
}

/// 主界面。
///
/// 只有两个功能（字幕翻译、同声传译），再给它们套一个系统 TabBar 就太笨重了：
/// 底部一整条黑/白栏，占掉几十 pt，还只放两个图标。
/// 这一版改成「一个工作台」：
///   · 顶部一行：品牌 + 头像（点头像进「我的」，不再占一个 Tab）
///   · 下面两个模式用一条细下划线切换，切换时内容淡入淡出
///   · 中间整块交给当前功能，底部只留一个主操作
/// 三个入口变成两个模式 + 一个抽屉，屏效比原来高，也更像专业工具。
struct MainView: View {
    @ObservedObject private var app = AppState.shared

    enum Mode: String, CaseIterable, Identifiable {
        case subtitle = "实时翻译"
        case interpreter = "同声传译"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .subtitle
    @State private var showProfile = false
    @Namespace private var segAnim

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                segment
                content
            }
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack { ProfileView() }
        }
        // 画中画的锚点必须挂在整个 App 的最外层，而不是某个页面里：
        // 锚点一离开窗口，系统就会把画中画收掉——切模式、进后台都属于这种情况。
        // 系统录屏面板也放这里，首页的按钮只是"借"它的点击。
        .overlay(
            ZStack {
                PipAnchor().frame(width: 1, height: 1)
                BroadcastPicker().frame(width: 60, height: 60)
            }
            .opacity(0.01)
            .allowsHitTesting(false)
        )
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .scaledToFill()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text("语幕")
                .font(.system(size: 19, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.ink)

            Spacer(minLength: 8)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showProfile = true
            } label: {
                AvatarView(size: 32)
                    .overlay(
                        Circle().strokeBorder(Theme.hairline, lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    // MARK: - 模式切换

    /// 两个模式各占一半、居中：整行等分，切换时下划线跟着走。
    private var segment: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { m in
                Button {
                    guard mode != m else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.22)) { mode = m }
                } label: {
                    VStack(spacing: 7) {
                        Text(m.rawValue)
                            .font(.system(size: 17, weight: mode == m ? .semibold : .regular))
                            .foregroundStyle(mode == m ? Theme.ink : Theme.sub)
                            .frame(maxWidth: .infinity)
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 2)
                            if mode == m {
                                Capsule()
                                    .fill(Theme.accent)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "seg", in: segAnim)
                            }
                        }
                        .frame(width: 56)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        Group {
            switch mode {
            case .subtitle:
                HomeView()
            case .interpreter:
                InterpreterView()
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: mode)
    }
}

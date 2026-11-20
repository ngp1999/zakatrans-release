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

/// 四个 Tab：字幕翻译 / 同声传译 / 网页 / 我的
struct MainView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("字幕翻译", systemImage: "captions.bubble.fill") }
                .tag(0)

            InterpreterView()
                .tabItem { Label("同声传译", systemImage: "arrow.left.arrow.right.circle.fill") }
                .tag(1)

            BrowserView()
                .tabItem { Label("网页", systemImage: "safari.fill") }
                .tag(2)

            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
                .tag(3)
        }
        .tint(Theme.accent)
        // 画中画的锚点必须挂在整个 App 的最外层，而不是某个页面里：
        // 锚点一离开窗口，系统就会把画中画收掉——切 Tab、进后台都属于这种情况。
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
}

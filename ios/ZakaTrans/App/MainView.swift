import SwiftUI

/// 入口：启动图 → 没登录就是登录页，登录后进主界面。
struct RootView: View {
    @ObservedObject private var cloud = Cloud.shared
    @State private var checking = true
    @State private var splash = true

    var body: some View {
        ZStack {
            if checking {
                ZStack {
                    Theme.bg.ignoresSafeArea()
                    ProgressView()
                }
            } else if cloud.loggedIn {
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
            await cloud.bootstrap()
            if cloud.loggedIn {
                await AppState.shared.syncPrefsFromCloud()
                await Purchases.shared.load()
                await Purchases.shared.syncUnfinished()
            }
            checking = false
            // 启动图停留一小会儿就淡出，不挡操作
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.easeOut(duration: 0.35)) { splash = false }
        }
    }
}

/// 两个 Tab：首页（实时翻译） / 我的
struct MainView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "waveform.circle.fill") }
                .tag(0)

            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
                .tag(1)
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

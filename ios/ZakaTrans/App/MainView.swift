import SwiftUI

/// 入口：没登录就是登录页，登录后进主界面。
struct RootView: View {
    @ObservedObject private var cloud = Cloud.shared
    @State private var checking = true

    var body: some View {
        Group {
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
        }
    }
}

/// 两个 Tab：首页（实时翻译） / 我的（账号、字幕、记录、积分）
struct MainView: View {
    @State private var tab = 0
    @ObservedObject private var cloud = Cloud.shared

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
    }
}

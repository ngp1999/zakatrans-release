import SwiftUI

/// 入口：启动图 → 没登录就是登录页，登录后进主界面。
struct RootView: View {
    @ObservedObject private var cloud = Cloud.shared
    @State private var splash = true

    var body: some View {
        ZStack {
            // 登录态没核完之前谁都不放进去：启动页挡在最上面。
            if cloud.ready {
                if cloud.loggedIn {
                    MainView()
                } else {
                    LoginView()
                }
            }

            if !cloud.ready || splash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(DSMotion.standard, value: cloud.loggedIn)
        .animation(DSMotion.standard, value: cloud.ready)
        .task {
            await cloud.bootstrap()
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(DSMotion.standard) { splash = false }

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

/// 主界面：系统 TabView。
///
/// 上一版是自绘的「悬浮玻璃头栏 + 分段控件」，那是把 Android / 网页的导航习惯搬到了 iOS 上。
/// iOS 原生 App 的做法就是系统 TabBar：三个平级入口、系统图标、系统选中态、
/// 系统自动处理安全区、动态字体、VoiceOver、深浅色。
///
/// 页面编号固定（.subtitle 是启动默认页），切到别的 Tab 再回来，状态由各页面自己保留。
struct MainView: View {
    enum Tab: Hashable {
        case subtitle
        case interpreter
        case me
    }

    @State private var tab: Tab = .subtitle

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView()
                    .navigationTitle("实时字幕")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("实时字幕", systemImage: "captions.bubble") }
            .tag(Tab.subtitle)

            NavigationStack {
                InterpreterView()
                    .navigationTitle("同声传译")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("同声传译", systemImage: "waveform") }
            .tag(Tab.interpreter)

            NavigationStack {
                ProfileView()
            }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
            .tag(Tab.me)
        }
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

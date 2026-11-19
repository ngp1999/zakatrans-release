import SwiftUI

struct MainView: View {
    @ObservedObject private var cloud = Cloud.shared
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("同传", systemImage: "waveform") }
                .tag(0)

            NavigationStack { WalletView() }
                .tabItem { Label("额度", systemImage: "creditcard") }
                .tag(1)

            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }
                .tag(2)
        }
        .tint(Theme.ink)
    }
}

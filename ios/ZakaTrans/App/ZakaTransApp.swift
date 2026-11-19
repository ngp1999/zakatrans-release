import SwiftUI

@main
struct ZakaTransApp: App {
    @StateObject private var cloud = Cloud.shared

    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(.light)
                .task {
                    await cloud.bootstrap()
                    await Purchases.shared.load()
                    await Purchases.shared.syncUnfinished()
                }
        }
    }
}

import SwiftUI

@main
struct ZakaTransApp: App {
    @ObservedObject private var cloud = Cloud.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    await cloud.bootstrap()
                    await Purchases.shared.load()
                    await Purchases.shared.syncUnfinished()
                }
        }
    }
}

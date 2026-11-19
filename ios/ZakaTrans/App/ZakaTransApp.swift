import SwiftUI

@main
struct ZakaTransApp: App {
    @ObservedObject private var cloud = Cloud.shared

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

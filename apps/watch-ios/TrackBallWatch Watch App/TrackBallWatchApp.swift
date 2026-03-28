import SwiftUI

@main
struct TrackBallWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager.shared
    @StateObject private var hostStore = HostStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .environmentObject(hostStore)
        }
    }
}

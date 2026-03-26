import SwiftUI
import WatchKit

@main
struct TrackBallWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager.shared
    @StateObject private var runtimeSession = ExtendedRuntimeManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .environmentObject(runtimeSession)
        }
    }
}

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore

    var body: some View {
        NavigationStack {
            TrackballView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .crownScrollHandler()
            .navigationTitle("TrackBall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: DiscoveryView()
                        .environmentObject(sessionManager)
                        .environmentObject(hostStore)) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }
}

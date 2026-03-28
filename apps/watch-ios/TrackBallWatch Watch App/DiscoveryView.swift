import SwiftUI

/// Shows mDNS-discovered desktops; tap to connect + add to host list.
struct DiscoveryView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore
    @StateObject private var browser = WatchBonjourBrowser.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if browser.isBrowsing && browser.discovered.isEmpty {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Searching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if browser.discovered.isEmpty {
                Text("No desktops found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(browser.discovered) { host in
                    Button {
                        connect(host)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(host.host):\(host.port)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Discover")
        .onAppear { browser.startBrowsing() }
        .onDisappear { browser.stopBrowsing() }
    }

    private func connect(_ discovered: DiscoveredHost) {
        let config = WatchDesktopConfig(
            host: discovered.host,
            port: discovered.port,
            deviceId: discovered.id,
            name: discovered.name
        )
        hostStore.addOrUpdate(config)
        sessionManager.connectDirectWiFi(to: config)
        sessionManager.playHaptic(.click)
        dismiss()
    }
}

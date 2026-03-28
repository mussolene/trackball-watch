import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore
    @StateObject private var browser = WatchBonjourBrowser.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if browser.isBrowsing && browser.discovered.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Searching…").font(.caption).foregroundStyle(.secondary)
                }
            } else if browser.discovered.isEmpty {
                Text("No desktops found").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(browser.discovered) { host in
                    Button { connect(host) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).font(.caption).lineLimit(1)
                            Text("\(host.host):\(host.port)")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Scan")
        .onAppear  { browser.startBrowsing() }
        .onDisappear { browser.stopBrowsing() }
    }

    private func connect(_ d: DiscoveredHost) {
        let cfg = WatchDesktopConfig(host: d.host, port: d.port, deviceId: d.id, name: d.name)
        hostStore.addOrUpdate(cfg)
        sessionManager.connectDirectWiFi(to: cfg)
        sessionManager.playHaptic(.click)
        dismiss()
    }
}

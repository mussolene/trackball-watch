import SwiftUI

/// Shows hosts discovered by the iPhone companion and pushed via WCSession.
/// Tapping connects the Watch directly via Wi-Fi UDP.
struct DiscoveryView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore
    @State private var scanning = false

    var body: some View {
        List {
            if hostStore.hosts.isEmpty {
                if scanning {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Asking iPhone…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No hosts yet").font(.caption).foregroundStyle(.secondary)
                    Button("Scan via iPhone") { requestScan() }
                        .font(.caption)
                }
            } else {
                ForEach(hostStore.hosts) { host in
                    Button { connect(host) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name).font(.caption).lineLimit(1)
                                Text(host.host).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if hostStore.activeId == host.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
                Button("Refresh") { requestScan() }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Hosts")
        .onAppear { if hostStore.hosts.isEmpty { requestScan() } }
    }

    private func connect(_ cfg: WatchDesktopConfig) {
        sessionManager.connectDirectWiFi(to: cfg)
        sessionManager.playHaptic(.click)
    }

    private func requestScan() {
        scanning = true
        sessionManager.requestPhoneScan()
        // iPhone will push updated host list; stop spinner after 5s regardless
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { scanning = false }
    }
}

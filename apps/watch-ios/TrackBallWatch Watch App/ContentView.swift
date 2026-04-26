import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore

    var body: some View {
        NavigationStack {
            Group {
                if sessionManager.mode == .trackball {
                    TrackballView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .crownScrollHandler()
                } else {
                    VStack(spacing: 6) {
                        // Transport + host indicator row
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)

                            // Tappable host name — opens picker if multiple hosts
                            Group {
                                if hostStore.hosts.count > 1 {
                                    NavigationLink(destination: HostPickerView()
                                        .environmentObject(sessionManager)
                                        .environmentObject(hostStore)) {
                                        hostLabel
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    hostLabel
                                }
                            }

                            Spacer()

                            // Transport badge
                            Text(transportBadge)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(transportBadgeColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(transportBadgeColor.opacity(0.15), in: Capsule())
                        }
                        .padding(.horizontal, 4)

                        Divider()

                        InputCaptureView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black.opacity(0.01))
                            .crownScrollHandler()
                    }
                }
            }
            .padding(4)
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

    // MARK: - Sub-views

    private var hostLabel: some View {
        Text(hostStore.activeHost?.name ?? statusText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch sessionManager.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        switch sessionManager.connectionState {
        case .connected:    return "Connected"
        case .connecting:   return "Connecting…"
        case .disconnected: return "Open iPhone app"
        }
    }

    private var transportBadge: String {
        switch sessionManager.transportMode {
        case .directWiFi: return "Wi-Fi"
        case .wcRelay:    return "relay"
        case .none:       return ""
        }
    }

    private var transportBadgeColor: Color {
        switch sessionManager.transportMode {
        case .directWiFi: return .green
        case .wcRelay:    return .orange
        case .none:       return .secondary
        }
    }
}

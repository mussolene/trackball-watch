import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // Connection status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)

                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                // Main touch surface — switches between trackpad and trackball
                if sessionManager.mode == .trackball {
                    TrackballView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    InputCaptureView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.01))
                }
            }
            .padding(4)
            .navigationTitle("TrackBall")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusColor: Color {
        switch sessionManager.connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        // WCSession: only “iPhone reachable” — not the Mac / UDP link.
        switch sessionManager.connectionState {
        case .connected: return "iPhone OK"
        case .connecting: return "Starting…"
        case .disconnected: return "Open iPhone app"
        }
    }
}

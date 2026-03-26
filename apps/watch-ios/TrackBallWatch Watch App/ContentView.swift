import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var runtime: ExtendedRuntimeManager

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

                // Mode indicator
                Text(sessionManager.mode == .trackpad ? "Trackpad" : "Trackball")
                    .font(.headline)
                    .foregroundStyle(.primary)

                // Main touch surface
                InputCaptureView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.01)) // required for gesture recognition
            }
            .padding(4)
            .navigationTitle("TrackBall")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            runtime.startSession()
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
        switch sessionManager.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }
}

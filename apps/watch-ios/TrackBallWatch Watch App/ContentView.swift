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

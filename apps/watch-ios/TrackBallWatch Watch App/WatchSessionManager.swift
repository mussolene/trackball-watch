import Foundation
import WatchConnectivity
import Combine

/// Manages WatchConnectivity session and TBP packet sending to iPhone.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    enum ConnectionState {
        case disconnected, connecting, connected
    }

    enum InputMode {
        case trackpad, trackball
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var mode: InputMode = .trackpad

    private var wcSession: WCSession?
    private var sequenceNumber: UInt16 = 0

    override private init() {
        super.init()
        activateSession()
    }

    private func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
        connectionState = .connecting
    }

    // MARK: - Packet sending

    /// Send a TBP packet via WatchConnectivity.
    /// Uses sendMessage for realtime delivery, falls back to transferUserInfo.
    func send(_ packet: TBPPacket) {
        guard let session = wcSession,
              session.activationState == .activated,
              session.isReachable else {
            return
        }

        sequenceNumber &+= 1
        let data = packet.serialize(seq: sequenceNumber)

        session.sendMessage(["d": data as Any], replyHandler: nil) { [weak self] error in
            // Fallback: transferUserInfo (slower, queued)
            self?.wcSession?.transferUserInfo(["d": data])
        }
    }

    // MARK: - Mode switching

    func toggleMode() {
        mode = (mode == .trackpad) ? .trackball : .trackpad
        WKInterfaceDevice.current().play(.click)
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            switch activationState {
            case .activated:
                connectionState = session.isReachable ? .connected : .connecting
            default:
                connectionState = .disconnected
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            connectionState = session.isReachable ? .connected : .connecting
        }
    }
}

// WKInterfaceDevice extension to suppress warnings
import WatchKit
extension WatchSessionManager {
    func playHaptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

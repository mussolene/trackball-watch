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
        guard WCSession.isSupported() else {
            connectionState = .disconnected
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
        connectionState = .connecting
    }

    /// `isReachable` is only true when the iPhone companion app is active enough for
    /// immediate messaging — not “connected to desktop”. Avoid showing `.connected` when
    /// the phone app is backgrounded / unreachable.
    private func applySessionState(_ session: WCSession) {
        switch session.activationState {
        case .notActivated:
            connectionState = .connecting
        case .inactive:
            connectionState = .disconnected
        case .activated:
            connectionState = session.isReachable ? .connected : .disconnected
        @unknown default:
            connectionState = .disconnected
        }
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
            if let error {
                self.connectionState = .disconnected
                return
            }
            self.applySessionState(session)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.applySessionState(session)
        }
    }

    /// Receive mode push from iPhone (originated from desktop CONFIG packet).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let modeStr = message["mode"] as? String else { return }
        Task { @MainActor in
            self.mode = modeStr == "trackball" ? .trackball : .trackpad
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

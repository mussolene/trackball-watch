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
    enum Handedness {
        case right, left
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var mode: InputMode = .trackpad
    @Published var hand: Handedness = .right

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
    /// Uses sendMessage for realtime delivery when reachable, otherwise queue via transferUserInfo.
    func send(_ packet: TBPPacket) {
        guard let session = wcSession,
              session.activationState == .activated else {
            return
        }

        sequenceNumber &+= 1
        let data = packet.serialize(seq: sequenceNumber)

        if session.isReachable {
            session.sendMessage(["d": data as Any], replyHandler: nil) { [weak self] _ in
                // Fallback when realtime path fails.
                self?.wcSession?.transferUserInfo(["d": data])
            }
        } else {
            // Companion is not foreground/reachable right now; queue delivery.
            session.transferUserInfo(["d": data])
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
            if error != nil {
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
        Task { @MainActor in
            if let modeStr = message["mode"] as? String {
                self.mode = modeStr == "trackball" ? .trackball : .trackpad
            }
            if let handStr = message["hand"] as? String {
                self.hand = handStr == "left" ? .left : .right
            }
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

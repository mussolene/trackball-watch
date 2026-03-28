import Foundation
import WatchConnectivity
import Network
import Combine

/// Manages input transport to the desktop:
///  1. Direct Wi-Fi (Watch → UDP → Desktop) — primary, low-latency
///  2. WCSession relay (Watch → BT → iPhone → UDP → Desktop) — fallback
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    // MARK: - Published state

    enum ConnectionState { case disconnected, connecting, connected }

    enum TransportMode {
        case directWiFi     /// Watch → UDP → Desktop
        case wcRelay        /// Watch → WCSession → iPhone → UDP → Desktop
        case none
    }

    enum InputMode  { case trackpad, trackball }
    enum Handedness { case right, left }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var transportMode: TransportMode = .none
    @Published var mode: InputMode = .trackpad
    @Published var hand: Handedness = .right
    @Published var trackballFriction: Double = 0.92
    @Published var coastingState: (vx: Double, vy: Double, active: Bool) = (0, 0, false)

    // MARK: - Private

    private var wcSession: WCSession?
    private var sequenceNumber: UInt16 = 0

    private var udpTransport: WatchUDPTransport?
    private var heartbeatTimer: Timer?

    // MARK: - Init

    override private init() {
        super.init()
        activateWCSession()
        // Auto-connect to last-known host on launch
        if let host = HostStore.shared.activeHost {
            connectDirectWiFi(to: host)
        }
    }

    // MARK: - WCSession

    private func activateWCSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
        if connectionState == .disconnected { connectionState = .connecting }
    }

    private func applyWCSessionState(_ session: WCSession) {
        // Only update from WCSession if UDP is not already connected
        guard udpTransport?.isReady != true else { return }
        switch session.activationState {
        case .notActivated:
            connectionState = .connecting
        case .inactive:
            connectionState = .disconnected
            transportMode = .none
        case .activated:
            if session.isReachable {
                connectionState = .connected
                transportMode = .wcRelay
            } else {
                connectionState = .disconnected
                transportMode = .none
            }
        @unknown default:
            connectionState = .disconnected
        }
    }

    // MARK: - Direct Wi-Fi

    /// Connect directly to a desktop via UDP, bypassing iPhone.
    func connectDirectWiFi(to config: WatchDesktopConfig) {
        // Cancel existing UDP transport
        udpTransport?.cancel()
        udpTransport = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        HostStore.shared.activate(config)

        let transport = WatchUDPTransport(host: config.host, port: config.port)
        transport.onConfigPacket  = { [weak self] mode, hand, friction in
            self?.applyConfig(mode: mode, hand: hand, frictionCenti: friction)
        }
        transport.onStateFeedback = { [weak self] coasting, vx, vy in
            self?.coastingState = (vx, vy, coasting)
        }
        transport.onStateChanged  = { [weak self] _ in self?.refreshConnectionState() }
        transport.start()
        udpTransport = transport

        // Heartbeat every 1s to keep desktop session alive (timeout = 3s)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let udp = self.udpTransport, udp.isReady else { return }
                self.sequenceNumber &+= 1
                let data = TBPPacket.heartbeat().serialize(seq: self.sequenceNumber)
                udp.send(data)
            }
        }
        refreshConnectionState()
    }

    private func refreshConnectionState() {
        if let udp = udpTransport {
            switch udp.state {
            case .ready:
                connectionState = .connected
                transportMode = .directWiFi
            case .connecting:
                connectionState = .connecting
                transportMode = .directWiFi
            case .waiting, .failed:
                // UDP struggling — fall back to showing WCSession state
                if let session = wcSession { applyWCSessionState(session) }
                else { connectionState = .disconnected; transportMode = .none }
            case .cancelled, .idle:
                if let session = wcSession { applyWCSessionState(session) }
                else { connectionState = .disconnected; transportMode = .none }
            }
        } else {
            if let session = wcSession { applyWCSessionState(session) }
        }
    }

    // MARK: - Packet sending

    /// Send a TBP packet via the best available transport.
    func send(_ packet: TBPPacket) {
        sequenceNumber &+= 1
        let data = packet.serialize(seq: sequenceNumber)

        // 1. Direct Wi-Fi (lowest latency)
        if let udp = udpTransport, udp.isReady {
            udp.send(data)
            return
        }

        // 2. WCSession relay fallback
        guard let session = wcSession, session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(["d": data as Any], replyHandler: nil) { [weak self] _ in
                self?.wcSession?.transferUserInfo(["d": data])
            }
        } else {
            session.transferUserInfo(["d": data])
        }
    }

    // MARK: - Mode

    func toggleMode() {
        mode = (mode == .trackpad) ? .trackball : .trackpad
        WKInterfaceDevice.current().play(.click)
    }

    // MARK: - Config from desktop

    func applyConfig(mode modeByte: UInt8, hand handByte: UInt8, frictionCenti: UInt8) {
        mode = modeByte == 1 ? .trackball : .trackpad
        hand = handByte == 1 ? .left : .right
        trackballFriction = min(0.99, max(0.5, Double(frictionCenti) / 100.0))
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
            if error != nil { self.connectionState = .disconnected; return }
            self.applyWCSessionState(session)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.applyWCSessionState(session) }
    }

    /// Receive CONFIG / STATE_FEEDBACK / mode push from iPhone (WCSession relay path).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if let modeStr = message["mode"] as? String {
                self.mode = modeStr == "trackball" ? .trackball : .trackpad
            }
            if let handStr = message["hand"] as? String {
                self.hand = handStr == "left" ? .left : .right
            }
            if let raw = message["friction"],
               let friction = (raw as? NSNumber)?.doubleValue ?? raw as? Double {
                self.trackballFriction = min(0.99, max(0.5, friction))
            }
            if let fb = message["state_fb"] as? [String: Any] {
                let vx      = (fb["vx"] as? NSNumber)?.doubleValue ?? 0
                let vy      = (fb["vy"] as? NSNumber)?.doubleValue ?? 0
                let active  = (fb["coasting"] as? Bool) ?? false
                self.coastingState = (vx, vy, active)
            }
        }
    }

    /// iPhone pushes the full host list via applicationContext (persistent, no reachability req).
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            guard let hostsRaw = applicationContext["hosts"] as? [[String: Any]] else { return }
            let configs = hostsRaw.compactMap { WatchDesktopConfig(from: $0) }
            guard !configs.isEmpty else { return }
            let phoneActiveId = applicationContext["activeId"] as? String
            HostStore.shared.mergeFromPhone(configs, phoneActiveId: phoneActiveId)

            // Auto-connect to the active host if UDP is not already ready
            if self.udpTransport?.isReady != true,
               let active = HostStore.shared.activeHost {
                self.connectDirectWiFi(to: active)
            }
        }
    }
}

// MARK: - WKInterfaceDevice helper
import WatchKit
extension WatchSessionManager {
    func playHaptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

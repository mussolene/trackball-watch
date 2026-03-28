import Foundation
import UIKit
import WatchConnectivity
import Network
import Combine
import OSLog

// MARK: - Host list sync

private let log = Logger(subsystem: "com.trackball-watch.app", category: "WatchRelay")

/// Core service: receives TBP packets from Apple Watch via WatchConnectivity
/// and relays them to the desktop host via UDP.
///
/// Architecture:
///   Apple Watch → WCSession.sendMessage → WatchRelayService → UDP → Desktop
@MainActor
final class WatchRelayService: NSObject, ObservableObject {
    enum DesktopLinkState: Equatable {
        case idle
        case connecting
        case connected
        case waiting(String)
        case failed(String)
    }

    static let shared = WatchRelayService()

    @Published var isRunning = false
    @Published var packetsRelayed: Int = 0
    @Published var desktopLinkState: DesktopLinkState = .idle

    private var wcSession: WCSession?
    private var udpRelay: UDPRelay?
    private var heartbeatTimer: Timer?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var pairedDesktop: DesktopConfig?

    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()
        // Load saved desktop config
        pairedDesktop = DesktopConfig.load()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        log.info("WatchRelayService starting, pairedDesktop=\(self.pairedDesktop?.host ?? "nil", privacy: .public)")
        activateWCSession()
        if let desktop = pairedDesktop {
            connectUDP(to: desktop)
        } else {
            desktopLinkState = .idle
        }
        isRunning = true

        // Push initial host list and watch for changes so Watch stays in sync
        pushHostListToWatch()
        PairingService.shared.$connections
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushHostListToWatch() }
            .store(in: &cancellables)
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        wcSession?.delegate = nil
        udpRelay?.cancel()
        udpRelay = nil
        cancellables.removeAll()
        isRunning = false
        desktopLinkState = .idle
        endBackgroundTask()
    }

    /// Push full host list to Watch via applicationContext.
    /// Delivered even when Watch app is not in foreground (unlike sendMessage).
    func pushHostListToWatch() {
        guard let session = wcSession, session.activationState == .activated else { return }
        let configs = PairingService.shared.connections
        guard !configs.isEmpty else { return }
        let payload: [[String: Any]] = configs.map { [
            "host": $0.host,
            "port": Int($0.port),
            "deviceId": $0.deviceId,
            "name": $0.name
        ]}
        let context: [String: Any] = [
            "hosts": payload,
            "activeId": PairingService.shared.activeId ?? ""
        ]
        do {
            try session.updateApplicationContext(context)
            log.info("Pushed \(configs.count, privacy: .public) hosts to Watch via applicationContext")
        } catch {
            log.warning("Failed to push host list to Watch: \(error, privacy: .public)")
        }
    }

    // MARK: - WatchConnectivity

    private func activateWCSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
    }

    // MARK: - UDP relay

    func connectUDP(to desktop: DesktopConfig) {
        log.info("connectUDP → \(desktop.host, privacy: .public):\(desktop.port, privacy: .public)")
        pairedDesktop = desktop
        DesktopConfig.save(desktop)

        udpRelay?.cancel()
        heartbeatTimer?.invalidate()

        let relay = UDPRelay(host: desktop.host, port: desktop.port)
        relay.onConfigPacket = { [weak self] modeByte, handByte, frictionByte in
            self?.pushModeToWatch(modeByte, handByte, frictionCenti: frictionByte)
        }
        relay.onStateFeedback = { [weak self] isCoasting, vx, vy in
            self?.pushStateFeedbackToWatch(isCoasting: isCoasting, vx: vx, vy: vy)
        }
        relay.onStateChanged = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connecting:
                self.desktopLinkState = .connecting
            case .ready:
                self.desktopLinkState = .connected
            case .waiting(let msg):
                self.desktopLinkState = .waiting(msg)
            case .failed(let msg):
                self.desktopLinkState = .failed(msg)
            case .cancelled:
                self.desktopLinkState = .idle
            }
        }
        relay.start()
        udpRelay = relay

        // Send heartbeats every 1s so the desktop session doesn't time out (timeout = 3s)
        // Timer closure is Sendable — access @MainActor property via Task
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.udpRelay?.sendHeartbeat() }
        }
    }

    func relay(_ data: Data) {
        udpRelay?.send(data)
        Task { @MainActor in
            packetsRelayed += 1
        }
    }

    private func switchDesktop(step: Int) {
        let all = PairingService.shared.connections
        guard !all.isEmpty else { return }

        let currentId = PairingService.shared.activeId
        let currentIndex = all.firstIndex { $0.deviceId == currentId } ?? 0
        let nextIndex = (currentIndex + step + all.count) % all.count
        PairingService.shared.activate(all[nextIndex])
    }

    /// Push mode change from desktop down to the Watch via WCSession.
    func pushModeToWatch(_ modeByte: UInt8, _ handByte: UInt8, frictionCenti: UInt8) {
        guard let session = wcSession,
              session.activationState == .activated,
              session.isReachable else { return }
        let modeString = modeByte == 1 ? "trackball" : "trackpad"
        let payload: [String: Any] = [
            "mode": modeString,
            "hand": handByte == 1 ? "left" : "right",
            "friction": Double(frictionCenti) / 100.0,
        ]
        session.sendMessage(payload, replyHandler: nil) { _ in
            // Non-critical — ignore errors
        }
    }

    /// Push desktop physics state to the Watch via WCSession (non-critical, best-effort).
    func pushStateFeedbackToWatch(isCoasting: Bool, vx: Double, vy: Double) {
        guard let session = wcSession,
              session.activationState == .activated,
              session.isReachable else { return }
        let payload: [String: Any] = [
            "state_fb": ["vx": vx, "vy": vy, "coasting": isCoasting] as [String: Any]
        ]
        session.sendMessage(payload, replyHandler: nil) { _ in
            // Non-critical — ignore errors
        }
    }

    // MARK: - Background execution

    func beginBackgroundTask() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "TBPRelay") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
}

// MARK: - WCSessionDelegate

extension WatchRelayService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error = error {
            log.error("WCSession activation error: \(error, privacy: .public)")
        } else {
            log.info("WCSession activated: \(activationState.rawValue, privacy: .public)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate() // Re-activate on watch switch
    }

    /// Real-time message from watch (primary path, < 5ms when active).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let command = message["cmd"] as? String {
            Task { @MainActor in
                switch command {
                case "next_host":
                    self.switchDesktop(step: 1)
                case "prev_host":
                    self.switchDesktop(step: -1)
                default:
                    break
                }
            }
            return
        }
        guard let data = message["d"] as? Data else { return }
        Task { @MainActor in
            self.relay(data)
        }
    }

    /// Queued message fallback (when watch app not in foreground).
    nonisolated func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        guard let data = userInfo["d"] as? Data else { return }
        Task { @MainActor in
            self.relay(data)
        }
    }
}

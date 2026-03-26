import Foundation
import AVFoundation
import CryptoKit

/// Handles device pairing:
///  1. QR code scan → parse tbp:// URL
///  2. Bonjour discovery → tap discovered desktop (optional PIN confirmation)
///  3. Manual entry → host + port typed manually
@MainActor
final class PairingService: ObservableObject {
    static let shared = PairingService()

    @Published var isPairing = false
    @Published var pairingError: String?
    @Published var isPaired = false

    // PIN pairing state
    @Published var pendingDesktop: DiscoveredDesktop?
    @Published var showPINEntry = false
    @Published var enteredPIN = ""

    private init() {
        isPaired = DesktopConfig.load() != nil
    }

    // MARK: - QR code parsing

    /// Parse a pairing QR code payload.
    /// Format: "tbp://pair?host=192.168.1.5&port=47474&id=<device-id>"
    func parsePairingURL(_ urlString: String) -> DesktopConfig? {
        guard let url = URL(string: urlString),
              url.scheme == "tbp",
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let host = params["host"],
              let portStr = params["port"],
              let port = UInt16(portStr),
              let deviceId = params["id"] else {
            return nil
        }

        return DesktopConfig(host: host, port: port, deviceId: deviceId)
    }

    // MARK: - Bonjour pairing

    /// Initiate pairing with a Bonjour-discovered desktop.
    /// If `requirePIN` is true, a PIN confirmation sheet is shown before connecting.
    func startPairing(with desktop: DiscoveredDesktop, requirePIN: Bool = true) {
        if requirePIN {
            pendingDesktop = desktop
            enteredPIN = ""
            showPINEntry = true
        } else {
            let config = DesktopConfig(host: desktop.host, port: desktop.port, deviceId: desktop.id)
            Task { await pair(with: config) }
        }
    }

    /// Called when user submits PIN from the PIN entry sheet.
    func confirmPIN() {
        guard let desktop = pendingDesktop else { return }
        let expectedPIN = Self.pin(for: desktop)
        if enteredPIN == expectedPIN || enteredPIN.isEmpty {
            // Empty PIN = skip verification (user trusted the device)
            let config = DesktopConfig(host: desktop.host, port: desktop.port, deviceId: desktop.id)
            Task { await pair(with: config) }
        } else {
            pairingError = "Wrong PIN. Check the code shown on the desktop."
        }
        showPINEntry = false
        pendingDesktop = nil
    }

    func cancelPIN() {
        showPINEntry = false
        pendingDesktop = nil
        pairingError = nil
    }

    /// Derive a short 6-digit PIN from the desktop's host string + current 5-minute window.
    /// Both desktop and phone compute the same value without exchanging secrets.
    static func pin(for desktop: DiscoveredDesktop) -> String {
        let window = Int(Date().timeIntervalSince1970) / 300  // 5-minute window
        let raw = "\(desktop.host):\(desktop.port)-\(window)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let value = digest.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self)
        }
        return String(format: "%06d", value % 1_000_000)
    }

    // MARK: - Core pairing flow

    func pair(with config: DesktopConfig) async {
        isPairing = true
        pairingError = nil

        WatchRelayService.shared.connectUDP(to: config)
        isPaired = true
        isPairing = false
    }

    func unpair() {
        DesktopConfig.clear()
        isPaired = false
        WatchRelayService.shared.stop()
    }
}

// MARK: - Desktop config model

struct DesktopConfig: Codable {
    let host: String
    let port: UInt16
    let deviceId: String

    private static let defaultsKey = "paired_desktop"

    static func load() -> DesktopConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(DesktopConfig.self, from: data)
    }

    static func save(_ config: DesktopConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

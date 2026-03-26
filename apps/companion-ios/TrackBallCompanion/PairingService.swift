import Foundation
import AVFoundation
import CryptoKit

/// Handles device pairing: QR code scan → ECDH handshake → session key storage.
@MainActor
final class PairingService: ObservableObject {
    static let shared = PairingService()

    @Published var isPairing = false
    @Published var pairingError: String?
    @Published var isPaired = false

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

    // MARK: - Pairing flow

    func pair(with config: DesktopConfig) async {
        isPairing = true
        pairingError = nil

        do {
            // Store config and connect
            WatchRelayService.shared.connectUDP(to: config)
            isPaired = true
            isPairing = false
        }
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

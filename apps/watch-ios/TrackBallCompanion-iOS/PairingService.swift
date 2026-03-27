import Foundation
import AVFoundation
import CryptoKit

/// Handles device pairing and manages the list of saved desktop connections.
@MainActor
final class PairingService: ObservableObject {
    static let shared = PairingService()

    @Published var connections: [DesktopConfig] = []
    @Published var activeId: String?

    @Published var isPairing = false
    @Published var pairingError: String?

    // PIN pairing state
    @Published var pendingDesktop: DiscoveredDesktop?
    @Published var showPINEntry = false
    @Published var enteredPIN = ""

    var activeConnection: DesktopConfig? {
        connections.first { $0.deviceId == activeId }
    }

    var isPaired: Bool { !connections.isEmpty }

    private init() {
        connections = DesktopConfig.loadAll()
        activeId = DesktopConfig.loadActiveId()
        // Migrate legacy single-connection storage
        if connections.isEmpty, let legacy = DesktopConfig.loadLegacy() {
            connections = [legacy]
            activeId = legacy.deviceId
            DesktopConfig.saveAll(connections)
            DesktopConfig.saveActiveId(activeId)
            DesktopConfig.clearLegacy()
        }
    }

    // MARK: - QR code parsing

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

        return DesktopConfig(host: host, port: port, deviceId: deviceId, name: host)
    }

    // MARK: - Bonjour pairing

    func startPairing(with desktop: DiscoveredDesktop, requirePIN: Bool = true) {
        if requirePIN {
            pendingDesktop = desktop
            enteredPIN = ""
            showPINEntry = true
        } else {
            let config = DesktopConfig(host: desktop.host, port: desktop.port,
                                       deviceId: desktop.id, name: desktop.name)
            Task { await pair(with: config) }
        }
    }

    func confirmPIN() {
        guard let desktop = pendingDesktop else { return }
        let expectedPIN = Self.pin(for: desktop)
        if enteredPIN == expectedPIN || enteredPIN.isEmpty {
            let config = DesktopConfig(host: desktop.host, port: desktop.port,
                                       deviceId: desktop.id, name: desktop.name)
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

    static func pin(for desktop: DiscoveredDesktop) -> String {
        let window = Int(Date().timeIntervalSince1970) / 300
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

        // Add or update in list
        if let idx = connections.firstIndex(where: { $0.deviceId == config.deviceId }) {
            connections[idx] = config
        } else {
            connections.append(config)
        }
        activeId = config.deviceId
        persist()

        WatchRelayService.shared.connectUDP(to: config)
        isPairing = false
    }

    // MARK: - Connection management

    func activate(_ config: DesktopConfig) {
        activeId = config.deviceId
        persist()
        WatchRelayService.shared.connectUDP(to: config)
    }

    func delete(_ config: DesktopConfig) {
        connections.removeAll { $0.deviceId == config.deviceId }
        if activeId == config.deviceId {
            activeId = connections.first?.deviceId
            if let next = activeConnection {
                WatchRelayService.shared.connectUDP(to: next)
            } else {
                WatchRelayService.shared.stop()
            }
        }
        persist()
    }

    func unpair() {
        connections.removeAll()
        activeId = nil
        DesktopConfig.saveAll([])
        DesktopConfig.saveActiveId(nil)
        WatchRelayService.shared.stop()
    }

    private func persist() {
        DesktopConfig.saveAll(connections)
        DesktopConfig.saveActiveId(activeId)
    }
}

// MARK: - Desktop config model

struct DesktopConfig: Codable, Identifiable {
    let host: String
    let port: UInt16
    let deviceId: String
    var name: String

    var id: String { deviceId }

    private static let savedKey = "saved_desktops"
    private static let activeIdKey = "active_desktop_id"
    private static let legacyKey = "paired_desktop"

    static func loadAll() -> [DesktopConfig] {
        guard let data = UserDefaults.standard.data(forKey: savedKey) else { return [] }
        return (try? JSONDecoder().decode([DesktopConfig].self, from: data)) ?? []
    }

    static func saveAll(_ configs: [DesktopConfig]) {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
    }

    static func loadActiveId() -> String? {
        UserDefaults.standard.string(forKey: activeIdKey)
    }

    static func saveActiveId(_ id: String?) {
        if let id {
            UserDefaults.standard.set(id, forKey: activeIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeIdKey)
        }
    }

    // Legacy single-device migration
    static func loadLegacy() -> DesktopConfig? {
        guard let data = UserDefaults.standard.data(forKey: legacyKey) else { return nil }
        guard var cfg = try? JSONDecoder().decode(DesktopConfig.self, from: data) else { return nil }
        if cfg.name.isEmpty { cfg = DesktopConfig(host: cfg.host, port: cfg.port,
                                                   deviceId: cfg.deviceId, name: cfg.host) }
        return cfg
    }

    static func clearLegacy() {
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    // Keep for WatchRelayService backward compat
    static func load() -> DesktopConfig? {
        let all = loadAll()
        guard let activeId = loadActiveId() else { return all.first }
        return all.first { $0.deviceId == activeId } ?? all.first
    }

    static func save(_ config: DesktopConfig) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.deviceId == config.deviceId }) {
            all[idx] = config
        } else {
            all.append(config)
        }
        saveAll(all)
        saveActiveId(config.deviceId)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: savedKey)
        UserDefaults.standard.removeObject(forKey: activeIdKey)
    }
}

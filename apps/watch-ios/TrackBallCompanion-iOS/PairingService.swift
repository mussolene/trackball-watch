import Foundation
import AVFoundation
import CryptoKit
import Darwin

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

        // Migrate stale link-local destinations to stable mDNS hostnames.
        let normalized = connections.map { cfg in
            let host = Self.normalizeHost(cfg.host, fallbackName: cfg.name)
            if host == cfg.host { return cfg }
            return DesktopConfig(host: host, port: cfg.port, deviceId: cfg.deviceId, name: cfg.name)
        }
        if normalized != connections {
            connections = normalized
            persist()
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
            let config = DesktopConfig(host: Self.normalizeHost(desktop.host, fallbackName: desktop.name), port: desktop.port,
                                       deviceId: desktop.id, name: desktop.name)
            Task { await pair(with: config) }
        }
    }

    func confirmPIN() {
        guard let desktop = pendingDesktop else { return }
        let expectedPIN = Self.pin(for: desktop)
        if enteredPIN == expectedPIN || enteredPIN.isEmpty {
            let config = DesktopConfig(host: Self.normalizeHost(desktop.host, fallbackName: desktop.name), port: desktop.port,
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

    private static func normalizeHost(_ host: String, fallbackName: String) -> String {
        if let resolved = resolveHostnameToLanIPv4(host) {
            return resolved
        }
        if host.hasPrefix("fe80:") || host.contains("%") || host.hasPrefix("169.254.") {
            let trimmed = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let resolved = resolveHostnameToLanIPv4("\(trimmed).local") {
                    return resolved
                }
            }
        }
        return host
    }

    private static func resolveHostnameToLanIPv4(_ hostname: String) -> String? {
        let parts = hostname.split(separator: ".")
        if parts.count == 4,
           let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]), let d = Int(parts[3]),
           (0...255).contains(a), (0...255).contains(b), (0...255).contains(c), (0...255).contains(d) {
            let isPrivate = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            return isPrivate ? hostname : nil
        }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(hostname, nil, &hints, &res)
        guard rc == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let ai = ptr {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    let p = ip.split(separator: ".").compactMap { Int($0) }
                    if p.count == 4 {
                        let isPrivate =
                            p[0] == 10 ||
                            (p[0] == 172 && (16...31).contains(p[1])) ||
                            (p[0] == 192 && p[1] == 168)
                        if isPrivate { return ip }
                    }
                }
            }
            ptr = ai.pointee.ai_next
        }
        return nil
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

    func activateNextConnection() {
        guard !connections.isEmpty else { return }
        let currentIndex = connections.firstIndex { $0.deviceId == activeId } ?? -1
        let nextIndex = (currentIndex + 1 + connections.count) % connections.count
        activate(connections[nextIndex])
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

struct DesktopConfig: Codable, Identifiable, Equatable {
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

import Foundation

/// Desktop connection config stored on the Watch.
/// Mirrors iPhone's DesktopConfig — synced via WCSession applicationContext.
struct WatchDesktopConfig: Codable, Identifiable, Equatable {
    let host: String
    let port: UInt16
    let deviceId: String
    var name: String

    var id: String { deviceId }

    /// Parse from dictionary (applicationContext payload from iPhone).
    init?(from dict: [String: Any]) {
        guard let host     = dict["host"] as? String,
              let deviceId = dict["deviceId"] as? String,
              let name     = dict["name"] as? String else { return nil }
        let port: UInt16
        if let p = dict["port"] as? Int      { port = UInt16(clamping: p) }
        else if let p = dict["port"] as? UInt16 { port = p }
        else { return nil }
        self.host = host; self.port = port; self.deviceId = deviceId; self.name = name
    }

    init(host: String, port: UInt16, deviceId: String, name: String) {
        self.host = host; self.port = port; self.deviceId = deviceId; self.name = name
    }
}

/// Persists and manages the list of desktop hosts on the Watch.
/// Source of truth: iPhone pushes via WCSession applicationContext; cached in UserDefaults.
@MainActor
final class HostStore: ObservableObject {
    static let shared = HostStore()

    @Published var hosts: [WatchDesktopConfig] = []
    @Published var activeId: String?

    var activeHost: WatchDesktopConfig? {
        hosts.first { $0.id == activeId } ?? hosts.first
    }

    private static let hostsKey  = "watch_hosts_v1"
    private static let activeKey = "watch_active_host_id"

    private init() { load() }

    func addOrUpdate(_ c: WatchDesktopConfig) {
        if let i = hosts.firstIndex(where: { $0.id == c.id }) { hosts[i] = c }
        else { hosts.append(c) }
        persist()
    }

    func activate(_ c: WatchDesktopConfig) {
        activeId = c.id
        UserDefaults.standard.set(c.id, forKey: Self.activeKey)
    }

    func remove(id: String) {
        hosts.removeAll { $0.id == id }
        if activeId == id {
            activeId = hosts.first?.id
            UserDefaults.standard.set(activeId, forKey: Self.activeKey)
        }
        persist()
    }

    /// Cycle to the next host in the list (for quick switching on watch).
    func cycleNext() {
        guard hosts.count > 1 else { return }
        let i = hosts.firstIndex { $0.id == activeId } ?? 0
        activate(hosts[(i + 1) % hosts.count])
    }

    func cyclePrev() {
        guard hosts.count > 1 else { return }
        let i = hosts.firstIndex { $0.id == activeId } ?? 0
        activate(hosts[(i - 1 + hosts.count) % hosts.count])
    }

    /// Replace host list from iPhone (via WCSession applicationContext).
    /// Preserves local activeId if still valid; falls back to phoneActiveId.
    func mergeFromPhone(_ configs: [WatchDesktopConfig], phoneActiveId: String?) {
        hosts = configs
        let localStillValid = activeId.map { id in configs.contains { $0.id == id } } ?? false
        if !localStillValid {
            activeId = phoneActiveId ?? configs.first?.id
        }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.hostsKey)
        }
        UserDefaults.standard.set(activeId, forKey: Self.activeKey)
    }

    private func load() {
        activeId = UserDefaults.standard.string(forKey: Self.activeKey)
        guard let data = UserDefaults.standard.data(forKey: Self.hostsKey) else { return }
        hosts = (try? JSONDecoder().decode([WatchDesktopConfig].self, from: data)) ?? []
    }
}

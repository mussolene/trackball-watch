import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.trackball-watch.watch", category: "Bonjour")

struct DiscoveredHost: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
}

/// Browses for `_tbp._udp.local.` via Wi-Fi only (prohibits BT relay through iPhone).
@MainActor
final class WatchBonjourBrowser: ObservableObject {
    static let shared = WatchBonjourBrowser()

    @Published var discovered: [DiscoveredHost] = []
    @Published var isBrowsing = false

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.trackball.watch.bonjour", qos: .userInitiated)

    private init() {}

    func startBrowsing() {
        stopBrowsing()
        discovered.removeAll()
        isBrowsing = true

        // Force direct Wi-Fi — prohibit BT relay (.other) and everything else
        let params = NWParameters()
        params.prohibitedInterfaceTypes = [.cellular, .other, .loopback, .wiredEthernet]

        // Note: type must include trailing dot to match dns-sd registration
        let b = NWBrowser(for: .bonjour(type: "_tbp._udp.", domain: "local."), using: params)

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .failed(let err):
                    log.error("Browser failed: \(err, privacy: .public)")
                    self?.isBrowsing = false
                case .cancelled:
                    self?.isBrowsing = false
                default: break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let activeNames = Set(results.compactMap {
                    guard case .service(let name, _, _, _) = $0.endpoint else { return nil as String? }
                    return name
                })
                self.discovered.removeAll { !activeNames.contains($0.name) }
                self.resolvers.keys.filter { !activeNames.contains($0) }.forEach { self.cancelResolver($0) }

                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    guard self.resolvers[name] == nil,
                          !self.discovered.contains(where: { $0.name == name }) else { continue }
                    self.resolve(result: result, name: name)
                }
            }
        }

        b.start(queue: queue)
        browser = b
        log.info("Bonjour browser started (Wi-Fi only)")
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        isBrowsing = false
    }

    // MARK: - Resolution

    private func resolve(result: NWBrowser.Result, name: String) {
        // Fast path: TXT records
        if case .bonjour(let txt) = result.metadata,
           let host = txtEntry(txt, "host"), !host.isEmpty {
            let port = txtEntry(txt, "port").flatMap { UInt16($0) } ?? 47474
            let deviceId = txtEntry(txt, "device_id") ?? name
            addHost(DiscoveredHost(id: deviceId, name: name, host: host, port: port))
            log.info("TXT resolved: \(name, privacy: .public) → \(host, privacy: .public):\(port)")
            return
        }

        // Slow path: connect to Bonjour endpoint → Network framework resolves SRV+A
        let connParams = NWParameters.udp
        connParams.prohibitedInterfaceTypes = [.cellular, .other, .loopback, .wiredEthernet]
        let conn = NWConnection(to: result.endpoint, using: connParams)
        resolvers[name] = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    if let path = conn.currentPath,
                       case .hostPort(let h, let p) = path.remoteEndpoint {
                        let host = "\(h)"
                        let port = p.rawValue
                        let deviceId: String
                        if case .bonjour(let txt) = result.metadata,
                           let id = self.txtEntry(txt, "device_id") {
                            deviceId = id
                        } else { deviceId = name }
                        log.info("Conn resolved: \(name, privacy: .public) → \(host, privacy: .public):\(port)")
                        self.addHost(DiscoveredHost(id: deviceId, name: name, host: host, port: port))
                    }
                    conn.cancel()
                    self.resolvers.removeValue(forKey: name)
                case .failed, .cancelled:
                    self.resolvers.removeValue(forKey: name)
                default: break
                }
            }
        }
        conn.start(queue: queue)

        // 5s timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard self?.resolvers[name] != nil else { return }
            log.warning("Resolve timeout: \(name, privacy: .public)")
            conn.cancel()
            self?.resolvers.removeValue(forKey: name)
        }
    }

    private func addHost(_ host: DiscoveredHost) {
        if let i = discovered.firstIndex(where: { $0.name == host.name }) {
            discovered[i] = host
        } else {
            discovered.append(host)
            discovered.sort { $0.name < $1.name }
        }
    }

    private func cancelResolver(_ name: String) {
        resolvers[name]?.cancel()
        resolvers.removeValue(forKey: name)
    }

    private func txtEntry(_ txt: NWTXTRecord, _ key: String) -> String? {
        switch txt.getEntry(for: key) {
        case .string(let s): return s.isEmpty ? nil : s
        case .data(let d):   return String(data: d, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        default:             return nil
        }
    }
}

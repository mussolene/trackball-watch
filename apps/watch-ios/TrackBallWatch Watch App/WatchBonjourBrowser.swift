import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.trackball-watch.watch", category: "Bonjour")

/// Discovered desktop host via mDNS.
struct DiscoveredHost: Identifiable, Equatable {
    let id: String          // device_id from TXT or service name
    let name: String        // service instance name
    let host: String        // resolved IP
    let port: UInt16        // resolved port
}

/// Browses for `_tbp._udp.local.` services using NWBrowser.
/// Resolves each found service to IP+port via NWConnection.
@MainActor
final class WatchBonjourBrowser: ObservableObject {
    static let shared = WatchBonjourBrowser()

    @Published var discovered: [DiscoveredHost] = []
    @Published var isBrowsing = false

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]   // keyed by service name
    private let queue = DispatchQueue(label: "com.trackball.watch.bonjour", qos: .userInitiated)

    private init() {}

    func startBrowsing() {
        stopBrowsing()
        discovered.removeAll()
        isBrowsing = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_tbp._udp", domain: "local.")
        let b = NWBrowser(for: descriptor, using: NWParameters())

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .failed(let err):
                    log.error("Browser failed: \(err, privacy: .public)")
                    self.isBrowsing = false
                case .cancelled:
                    self.isBrowsing = false
                default: break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Remove stale resolved entries
                let activeNames = Set(results.compactMap { result -> String? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return name
                })
                self.discovered.removeAll { !activeNames.contains($0.name) }
                self.resolvers.keys
                    .filter { !activeNames.contains($0) }
                    .forEach { self.cancelResolver(name: $0) }

                // Resolve newly discovered services
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    guard self.resolvers[name] == nil else { continue }  // already resolving
                    self.resolve(result: result, name: name)
                }
            }
        }

        b.start(queue: queue)
        browser = b
        log.info("Bonjour browser started")
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        isBrowsing = false
    }

    // MARK: - Resolution

    /// Resolve a Bonjour service endpoint → IP + port via a transient NWConnection.
    private func resolve(result: NWBrowser.Result, name: String) {
        // First try TXT records for fast path (avoids connection overhead)
        if case .bonjour(let txt) = result.metadata,
           let host = txtString(txt, key: "host"), !host.isEmpty {
            let port = txtString(txt, key: "port").flatMap { UInt16($0) } ?? 47474
            let deviceId = txtString(txt, key: "device_id") ?? name
            log.info("Resolved via TXT: \(name, privacy: .public) → \(host, privacy: .public):\(port)")
            addHost(DiscoveredHost(id: deviceId, name: name, host: host, port: port))
            return
        }

        // Slow path: connect and let Network framework resolve the endpoint
        let conn = NWConnection(to: result.endpoint, using: NWParameters.udp)
        resolvers[name] = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.extractAddress(from: conn, name: name, fallbackResult: result)
                    conn.cancel()
                    self.resolvers.removeValue(forKey: name)
                case .failed(let err):
                    log.warning("Resolve failed for \(name, privacy: .public): \(err, privacy: .public)")
                    conn.cancel()
                    self.resolvers.removeValue(forKey: name)
                case .cancelled:
                    self.resolvers.removeValue(forKey: name)
                default: break
                }
            }
        }
        conn.start(queue: queue)
        log.info("Resolving via connection: \(name, privacy: .public)")

        // Timeout after 5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak conn] in
            guard let self, self.resolvers[name] != nil else { return }
            log.warning("Resolve timeout for \(name, privacy: .public)")
            conn?.cancel()
            self.resolvers.removeValue(forKey: name)
        }
    }

    private func extractAddress(from conn: NWConnection, name: String, fallbackResult: NWBrowser.Result) {
        guard let path = conn.currentPath else { return }
        let remote = path.remoteEndpoint

        var host: String?
        var port: UInt16 = 47474

        if case .hostPort(let h, let p) = remote {
            host = "\(h)"
            port = p.rawValue
        }

        guard let resolvedHost = host, !resolvedHost.isEmpty else {
            log.warning("No IP from path for \(name, privacy: .public)")
            return
        }

        // Try device_id from TXT
        var deviceId = name
        if case .bonjour(let txt) = fallbackResult.metadata,
           let id = txtString(txt, key: "device_id") {
            deviceId = id
        }

        log.info("Resolved: \(name, privacy: .public) → \(resolvedHost, privacy: .public):\(port)")
        addHost(DiscoveredHost(id: deviceId, name: name, host: resolvedHost, port: port))
    }

    private func addHost(_ host: DiscoveredHost) {
        if let i = discovered.firstIndex(where: { $0.name == host.name }) {
            discovered[i] = host
        } else {
            discovered.append(host)
            discovered.sort { $0.name < $1.name }
        }
    }

    private func cancelResolver(name: String) {
        resolvers[name]?.cancel()
        resolvers.removeValue(forKey: name)
    }

    // MARK: - TXT helpers

    private func txtString(_ txt: NWTXTRecord, key: String) -> String? {
        switch txt.getEntry(for: key) {
        case .string(let s): return s.isEmpty ? nil : s
        case .data(let d):   return String(data: d, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        default:             return nil
        }
    }
}

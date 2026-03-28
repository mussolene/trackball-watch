import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.trackball-watch.watch", category: "Bonjour")

/// Discovered desktop host via mDNS.
struct DiscoveredHost: Identifiable, Equatable {
    let id: String          // device_id from TXT
    let name: String        // service instance name
    let host: String        // IP from TXT `host=` field
    let port: UInt16        // port from TXT `port=` field
}

/// Browses for `_tbp._udp.local.` services using NWBrowser.
/// Requires `com.apple.developer.networking.multicast` entitlement on real hardware.
@MainActor
final class WatchBonjourBrowser: ObservableObject {
    static let shared = WatchBonjourBrowser()

    @Published var discovered: [DiscoveredHost] = []
    @Published var isBrowsing = false

    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.trackball.watch.bonjour", qos: .userInitiated)

    private init() {}

    func startBrowsing() {
        guard !isBrowsing else { return }
        stopBrowsing()
        discovered.removeAll()

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_tbp._udp", domain: "local.")
        let params = NWParameters.udp
        params.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: params)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    log.info("Bonjour browser ready")
                    self.isBrowsing = true
                case .failed(let err):
                    log.error("Bonjour browser failed: \(err, privacy: .public)")
                    self.isBrowsing = false
                case .cancelled:
                    self.isBrowsing = false
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.processResults(results)
            }
        }
        b.start(queue: queue)
        browser = b
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        resolvers.forEach { $0.cancel() }
        resolvers.removeAll()
        isBrowsing = false
    }

    // MARK: - Private

    private func processResults(_ results: Set<NWBrowser.Result>) {
        var hosts: [DiscoveredHost] = []

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            if case .bonjour(let txt) = result.metadata {
                if let host = extractTXTValue(txt, key: "host"),
                   let portStr = extractTXTValue(txt, key: "port"),
                   let portNum = UInt16(portStr),
                   !host.isEmpty {
                    let deviceId = extractTXTValue(txt, key: "device_id") ?? name
                    hosts.append(DiscoveredHost(id: deviceId, name: name, host: host, port: portNum))
                    log.info("Found: \(name, privacy: .public) @ \(host, privacy: .public):\(portStr, privacy: .public)")
                }
            }
        }

        // Sort by name for stable display
        discovered = hosts.sorted { $0.name < $1.name }
    }

    private func extractTXTValue(_ txt: NWTXTRecord, key: String) -> String? {
        switch txt.getEntry(for: key) {
        case .string(let s): return s.isEmpty ? nil : s
        default: return nil
        }
    }
}

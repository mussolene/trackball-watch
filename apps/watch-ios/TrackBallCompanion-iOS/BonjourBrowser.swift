import Foundation
import Network
import Combine

/// Discovered desktop via mDNS/Bonjour (_tbp._udp.local).
struct DiscoveredDesktop: Identifiable, Equatable {
    let id: String          // service name (unique per desktop)
    let name: String        // human-readable name (e.g. "Mac Pro")
    let host: String
    let port: UInt16

    static func == (lhs: DiscoveredDesktop, rhs: DiscoveredDesktop) -> Bool {
        lhs.id == rhs.id
    }
}

/// Browses the local network for TBP desktop hosts advertising _tbp._udp.local.
@MainActor
final class BonjourBrowser: ObservableObject {
    @Published var discovered: [DiscoveredDesktop] = []
    @Published var isSearching = false

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.trackball.bonjour", qos: .userInitiated)

    func start() {
        guard browser == nil else { return }
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: .bonjour(type: "_tbp._udp.", domain: "local."), using: params)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed = state {
                    self?.isSearching = false
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResults(results)
            }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        isSearching = false
        discovered.removeAll()
    }

    // MARK: - Private

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var current: [DiscoveredDesktop] = []

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            // Resolve host+port via NWConnection
            let conn = NWConnection(to: result.endpoint, using: .udp)
            resolvers[name]?.cancel()
            resolvers[name] = conn

            conn.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    if let path = conn.currentPath,
                       let endpoint = path.remoteEndpoint,
                       case .hostPort(let host, let port) = endpoint {
                        let hostStr = "\(host)"
                        let portVal = port.rawValue
                        let desktop = DiscoveredDesktop(
                            id: name,
                            name: name,
                            host: hostStr,
                            port: portVal
                        )
                        Task { @MainActor [weak self] in
                            self?.upsert(desktop)
                        }
                    }
                    conn.cancel()
                }
            }
            conn.start(queue: self.queue)
        }

        // Remove desktops no longer visible
        let activeNames = Set(results.compactMap { result -> String? in
            if case .service(let name, _, _, _) = result.endpoint { return name }
            return nil
        })
        discovered.removeAll { !activeNames.contains($0.id) }
    }

    private func upsert(_ desktop: DiscoveredDesktop) {
        if let idx = discovered.firstIndex(where: { $0.id == desktop.id }) {
            discovered[idx] = desktop
        } else {
            discovered.append(desktop)
        }
    }
}

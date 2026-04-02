import Foundation
import Network
import Combine
import OSLog
import Darwin

private let log = Logger(subsystem: "com.trackball-watch.app", category: "BonjourBrowser")

/// Discovered desktop via mDNS/Bonjour (_tbp._udp.local).
struct DiscoveredDesktop: Identifiable, Equatable {
    /// Stable key: `device_id` from TXT when present, else Bonjour instance name.
    let id: String
    /// Bonjour instance name (e.g. TrackBall-cac7877e-00).
    let name: String
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
    private var resolvers: [String: ServiceResolver] = [:]
    private let queue = DispatchQueue(label: "com.trackball.bonjour", qos: .userInitiated)

    func start() {
        guard browser == nil else { return }
        isSearching = true
        log.info("Starting Bonjour browser for _tbp._udp.local.")

        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: .bonjour(type: "_tbp._udp.", domain: "local."), using: params)
        b.stateUpdateHandler = { [weak self] state in
            log.info("Browser state: \(String(describing: state), privacy: .public)")
            Task { @MainActor [weak self] in
                if case .failed(let err) = state {
                    log.error("Browser failed: \(err, privacy: .public)")
                    self?.isSearching = false
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            log.info("Browse results changed: \(results.count, privacy: .public) results")
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
        resolvers.values.forEach { $0.stop() }
        resolvers.removeAll()
        isSearching = false
        discovered.removeAll()
    }

    // MARK: - Private

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        log.info("Handling \(results.count, privacy: .public) Bonjour results")
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            log.info("Found service: \(name, privacy: .public)")

            // Fast path: desktop hosts (e.g. Rust mdns-sd on Windows) often ship full TXT in the
            // browse result. NetService.resolve can still fail for non-Apple responders — show the
            // host immediately when TXT has host (+ optional port).
            if let quick = Self.discoveredDesktopFromBrowseTXT(instanceName: name, metadata: result.metadata) {
                Task { @MainActor [weak self] in
                    self?.upsert(quick)
                }
            }

            let metadataHost = Self.hostFromBonjourMetadata(result.metadata)
            let resolver = ServiceResolver(name: name, type: type, domain: domain) { [weak self] desktop in
                let preferredHost = Self.preferredHost(metadataHost: metadataHost, resolvedHost: desktop.host)
                let merged = DiscoveredDesktop(
                    id: desktop.id,
                    name: desktop.name,
                    host: preferredHost,
                    port: desktop.port
                )
                Task { @MainActor [weak self] in
                    self?.upsert(merged)
                }
            }
            resolvers[name]?.stop()
            resolvers[name] = resolver
            resolver.start()
        }

        // Remove desktops no longer visible
        let activeNames = Set(results.compactMap { result -> String? in
            if case .service(let name, _, _, _) = result.endpoint { return name }
            return nil
        })
        resolvers = resolvers.filter { activeNames.contains($0.key) }
        // `id` is often `device_id` from TXT, not Bonjour instance name — match on `name`.
        discovered.removeAll { !activeNames.contains($0.name) }
    }

    private func upsert(_ desktop: DiscoveredDesktop) {
        if let sameEndpointIdx = discovered.firstIndex(where: {
            $0.host == desktop.host && $0.port == desktop.port && $0.id != desktop.id
        }) {
            // De-duplicate duplicate mDNS advertisements of the same host:port
            // that differ only by service instance name/interface suffix.
            if desktop.name.count < discovered[sameEndpointIdx].name.count {
                discovered[sameEndpointIdx] = DiscoveredDesktop(
                    id: desktop.id,
                    name: desktop.name,
                    host: desktop.host,
                    port: desktop.port
                )
            }
            return
        }
        if let idx = discovered.firstIndex(where: { $0.id == desktop.id }) {
            discovered[idx] = desktop
        } else {
            discovered.append(desktop)
        }
    }

    private static func preferredHost(metadataHost: String?, resolvedHost: String) -> String {
        if let metadataHost, let ipv4 = lanIPv4(from: metadataHost) {
            return ipv4
        }
        if let ipv4 = lanIPv4(from: resolvedHost) {
            return ipv4
        }
        return resolvedHost
    }

    /// Case-insensitive TXT lookup (mDNS keys are often lowercase from non-Apple stacks).
    private static func txtValue(_ txt: [String: String], key: String) -> String? {
        if let v = txt[key] { return v }
        return txt.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    private static func hostFromBonjourMetadata(_ metadata: NWBrowser.Result.Metadata) -> String? {
        guard case let .bonjour(txtRecord) = metadata else { return nil }
        let txt = txtRecord.dictionary
        guard let host = txtValue(txt, key: "host")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    /// Build a row from browse TXT alone (no NetService.resolve).
    private static func discoveredDesktopFromBrowseTXT(
        instanceName: String,
        metadata: NWBrowser.Result.Metadata
    ) -> DiscoveredDesktop? {
        guard case let .bonjour(txtRecord) = metadata else { return nil }
        let txt = txtRecord.dictionary
        guard let hostRaw = txtValue(txt, key: "host")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostRaw.isEmpty else {
            return nil
        }
        guard let host = lanIPv4(from: hostRaw) else { return nil }
        let portStr = txtValue(txt, key: "port") ?? "47474"
        guard let port = UInt16(portStr) else { return nil }
        let did = txtValue(txt, key: "device_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableId = (did?.isEmpty == false) ? did! : instanceName
        return DiscoveredDesktop(id: stableId, name: instanceName, host: host, port: port)
    }

    private static func isRoutableHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasPrefix("169.254.") || h.hasPrefix("127.") || h == "0.0.0.0" { return false }
        if h.hasPrefix("fe80:") || h == "::1" || h.contains("%") { return false }
        // Keep discovery within LAN/Wi-Fi segments for stable relay.
        if let v4 = ipv4Octets(h) {
            let isPrivate =
                v4.0 == 10 ||
                (v4.0 == 172 && (16...31).contains(v4.1)) ||
                (v4.0 == 192 && v4.1 == 168)
            if !isPrivate { return false }
        }
        return true
    }

    private static func lanIPv4(from host: String) -> String? {
        if let v4 = ipv4Octets(host) {
            let isPrivate =
                v4.0 == 10 ||
                (v4.0 == 172 && (16...31).contains(v4.1)) ||
                (v4.0 == 192 && v4.1 == 168)
            if isPrivate { return host }
            return nil
        }
        return resolveHostnameToLanIPv4(host)
    }

    private static func resolveHostnameToLanIPv4(_ hostname: String) -> String? {
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
            if ai.pointee.ai_family == AF_INET,
               let sa = ai.pointee.ai_addr {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    if lanIPv4(from: ip) != nil { return ip }
                }
            }
            ptr = ai.pointee.ai_next
        }
        return nil
    }

    private static func ipv4Octets(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return (nums[0], nums[1], nums[2], nums[3])
    }

    private final class ServiceResolver: NSObject, NetServiceDelegate {
        private let service: NetService
        private let onResolved: (DiscoveredDesktop) -> Void

        init(name: String, type: String, domain: String, onResolved: @escaping (DiscoveredDesktop) -> Void) {
            // NetService requires type/domain with trailing dots; NWBrowser sometimes omits them.
            let dom = Self.normalizedDomain(domain)
            let typ = Self.normalizedServiceType(type)
            self.service = NetService(domain: dom, type: typ, name: name)
            self.onResolved = onResolved
            super.init()
            self.service.delegate = self
        }

        private static func normalizedDomain(_ domain: String) -> String {
            var d = domain
            if d.isEmpty { return "local." }
            if !d.hasSuffix(".") { d += "." }
            return d
        }

        private static func normalizedServiceType(_ type: String) -> String {
            var t = type
            if !t.hasSuffix(".") { t += "." }
            return t
        }

        func start() {
            service.resolve(withTimeout: 5)
        }

        func stop() {
            service.stop()
        }

        func netServiceDidResolveAddress(_ sender: NetService) {
            let port = UInt16(sender.port)
            let txtHost = Self.txtHost(from: sender)
            let ipv4Host = sender.addresses?
                .compactMap(Self.ipv4Address)
                .first(where: { Self.isRoutableIPv4($0) })
            let hostName = sender.hostName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let host = [txtHost, ipv4Host, hostName].compactMap({ $0 }).first,
                  !host.isEmpty else {
                log.warning("NetService resolved without usable host for \(sender.name, privacy: .public)")
                sender.stop()
                return
            }

            log.info("NetService resolved \(sender.name, privacy: .public) → \(host, privacy: .public):\(port, privacy: .public)")
            let did = Self.txtDeviceId(from: sender)
            let stableId = (did?.isEmpty == false) ? did! : sender.name
            onResolved(DiscoveredDesktop(id: stableId, name: sender.name, host: host, port: port))
            sender.stop()
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
            log.warning("NetService resolve failed for \(sender.name, privacy: .public): \(errorDict, privacy: .public)")
        }

        private static func txtHost(from service: NetService) -> String? {
            guard let txtRecord = service.txtRecordData() else { return nil }
            let txt = NetService.dictionary(fromTXTRecord: txtRecord)
            for key in txt.keys {
                if key.lowercased() == "host", let data = txt[key],
                   let host = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
                    return host
                }
            }
            return nil
        }

        private static func txtDeviceId(from service: NetService) -> String? {
            guard let txtRecord = service.txtRecordData() else { return nil }
            let txt = NetService.dictionary(fromTXTRecord: txtRecord)
            for key in txt.keys {
                if key.lowercased() == "device_id", let data = txt[key],
                   let s = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    return s
                }
            }
            return nil
        }

        private static func ipv4Address(from addressData: Data) -> String? {
            addressData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return nil }
                let sockaddrPtr = base.assumingMemoryBound(to: sockaddr.self)
                guard sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }

                var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr, &hostBuffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: hostBuffer)
            }
        }

        private static func isRoutableIPv4(_ host: String) -> Bool {
            // Reject link-local and loopback addresses for relay destination.
            !(host.hasPrefix("169.254.") || host.hasPrefix("127."))
        }
    }
}

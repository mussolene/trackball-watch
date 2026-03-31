import Foundation
import Network
import OSLog
import Darwin

private let log = Logger(subsystem: "com.trackball-watch.app", category: "UDPRelay")

/// UDP client that sends TBP packets to the desktop host.
/// Also receives inbound CONFIG packets from desktop to sync mode changes.
final class UDPRelay {
    enum RelayState: Equatable {
        case connecting
        case ready
        case waiting(String)
        case failed(String)
        case cancelled
    }

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.trackball.udp", qos: .userInteractive)
    private var seq: UInt16 = 0
    /// True only after `NWConnection` reaches `.ready`. Watch packets often arrive earlier; without a queue they were dropped.
    private var isPathReady = false
    private var pendingOutbound: [Data] = []
    private let maxPendingOutbound = 512

    /// Called on main thread when a CONFIG packet (type 0x12) is received.
    /// Payload is fixed 2 bytes: mode, friction (centi-units 50–99 → 0.50–0.99).
    var onConfigPacket: ((UInt8, UInt8) -> Void)?
    /// Called on main thread when a STATE_FEEDBACK packet (type 0x13) is received.
    /// Parameters: isCoasting, vx (pixels/frame), vy (pixels/frame).
    var onStateFeedback: ((Bool, Double, Double) -> Void)?
    /// Called on main thread when UDP relay state changes.
    var onStateChanged: ((RelayState) -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() {
        let resolvedHost = Self.resolveRoutableHost(host) ?? host
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(resolvedHost),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(to: endpoint, using: params)
        let hostCopy = resolvedHost, portCopy = port
        log.info("Connecting UDP to \(hostCopy, privacy: .public):\(portCopy, privacy: .public) (configured: \(self.host, privacy: .public))")
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup, .preparing:
                DispatchQueue.main.async { self.onStateChanged?(.connecting) }
            case .ready:
                log.info("UDP ready → \(hostCopy, privacy: .public):\(portCopy, privacy: .public)")
                self.isPathReady = true
                DispatchQueue.main.async { self.onStateChanged?(.ready) }
                guard let conn = self.connection else { return }
                log.info("Sending HANDSHAKE")
                self.sendNow(self.buildPacket(type: 0x10, payload: Data()), connection: conn)
                self.receiveLoop()
                self.flushPendingOutbound()
            case .failed(let error):
                self.isPathReady = false
                self.pendingOutbound.removeAll()
                log.error("UDP failed: \(error, privacy: .public)")
                DispatchQueue.main.async { self.onStateChanged?(.failed(error.localizedDescription)) }
            case .waiting(let error):
                log.warning("UDP waiting: \(error, privacy: .public)")
                DispatchQueue.main.async { self.onStateChanged?(.waiting(error.localizedDescription)) }
            case .cancelled:
                self.isPathReady = false
                self.pendingOutbound.removeAll()
                DispatchQueue.main.async { self.onStateChanged?(.cancelled) }
            default:
                log.debug("UDP state: \(String(describing: state), privacy: .public)")
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1500) { [weak self] data, _, _, error in
            if let data, data.count >= 9 {
                // Header: [seq:2][type:1][flags:1][ts:4] = 8 bytes, payload starts at byte 8
                let packetType = data[2]
                if packetType == 0x12, data.count >= 10 { // CONFIG: 8-byte header + 2-byte payload
                    let modeByte = data[8]
                    let frictionByte = data[9]
                    DispatchQueue.main.async { self?.onConfigPacket?(modeByte, frictionByte) }
                }
                if packetType == 0x13, data.count >= 13 { // STATE_FEEDBACK: header(8) + coasting(1) + vx_fp(2) + vy_fp(2)
                    let isCoasting = data[8] != 0
                    let vxFP = Int16(bitPattern: UInt16(data[9]) | (UInt16(data[10]) << 8))
                    let vyFP = Int16(bitPattern: UInt16(data[11]) | (UInt16(data[12]) << 8))
                    let vx = Double(vxFP) / 64.0
                    let vy = Double(vyFP) / 64.0
                    DispatchQueue.main.async { self?.onStateFeedback?(isCoasting, vx, vy) }
                }
            }
            if error == nil { self?.receiveLoop() } // continue receiving
        }
    }

    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let conn = self.connection else {
                log.warning("UDP send dropped: no connection (len=\(data.count))")
                return
            }
            if !self.isPathReady {
                self.enqueuePending(data)
                return
            }
            self.sendNow(data, connection: conn)
        }
    }

    private func enqueuePending(_ data: Data) {
        if pendingOutbound.count >= maxPendingOutbound {
            let drop = pendingOutbound.count - maxPendingOutbound + 1
            pendingOutbound.removeFirst(drop)
            log.warning("UDP pending queue overflow, dropped \(drop) older packets")
        }
        pendingOutbound.append(data)
        log.debug("UDP queued packet until ready (pending=\(self.pendingOutbound.count), len=\(data.count))")
    }

    private func flushPendingOutbound() {
        guard let conn = connection else { return }
        guard !pendingOutbound.isEmpty else { return }
        let batch = pendingOutbound
        pendingOutbound.removeAll(keepingCapacity: true)
        log.info("Flushing \(batch.count) UDP packets queued before ready")
        for data in batch {
            sendNow(data, connection: conn)
        }
    }

    private func sendNow(_ data: Data, connection conn: NWConnection) {
        conn.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                log.error("UDP send failed: \(error, privacy: .public) len=\(data.count)")
            }
        })
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isPathReady = false
            self.pendingOutbound.removeAll()
            self.connection?.cancel()
            self.connection = nil
        }
        DispatchQueue.main.async { self.onStateChanged?(.cancelled) }
    }

    // MARK: - TBP control packets

    /// Send a HANDSHAKE packet to initiate a session on the desktop.
    /// Packet format: [seq:u16 LE][type:u8=0x10][flags:u8=0][timestamp_us:u32 LE]
    func sendHandshake() {
        queue.async { [weak self] in
            guard let self, let conn = self.connection, self.isPathReady else { return }
            log.info("Sending HANDSHAKE")
            self.sendNow(self.buildPacket(type: 0x10, payload: Data()), connection: conn)
        }
    }

    /// Send a HEARTBEAT packet to keep the session alive.
    func sendHeartbeat() {
        log.debug("Sending HEARTBEAT")
        send(buildPacket(type: 0x11, payload: Data()))
    }

    // MARK: - Private

    private func buildPacket(type packetType: UInt8, payload: Data) -> Data {
        seq &+= 1
        let timestampUs = Self.timestampUsLower32()
        var data = Data(capacity: 8 + payload.count)
        data.appendLE(seq)
        data.append(packetType)
        data.append(0) // flags
        data.appendLE(timestampUs)
        data.append(payload)
        return data
    }

    private static func timestampUsLower32() -> UInt32 {
        let secs = Date().timeIntervalSince1970
        guard secs.isFinite, secs >= 0 else { return 0 }
        guard secs <= Double(Int64.max) / 1_000_000.0 else {
            return UInt32(truncatingIfNeeded: UInt64.max)
        }
        let microsDouble = secs * 1_000_000.0
        guard microsDouble.isFinite, microsDouble >= 0, microsDouble <= Double(Int64.max) else { return 0 }
        let micros = Int64(microsDouble)
        guard micros >= 0 else { return 0 }
        return UInt32(truncatingIfNeeded: UInt64(micros))
    }

    /// Resolve hostname and prefer routable LAN addresses over link-local.
    private static func resolveRoutableHost(_ input: String) -> String? {
        // Already a numeric host: keep if not link-local.
        if isRoutableIPv4(input) || isRoutableIPv6(input) {
            return input
        }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(input, nil, &hints, &res)
        guard rc == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }

        var bestIPv4: String?
        var bestIPv6: String?
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let ai = ptr {
            if ai.pointee.ai_family == AF_INET,
               let ip = ipv4String(from: ai.pointee.ai_addr),
               isRoutableIPv4(ip) {
                bestIPv4 = ip
                break
            } else if ai.pointee.ai_family == AF_INET6,
                      let ip = ipv6String(from: ai.pointee.ai_addr),
                      isRoutableIPv6(ip),
                      bestIPv6 == nil {
                bestIPv6 = ip
            }
            ptr = ai.pointee.ai_next
        }
        return bestIPv4 ?? bestIPv6
    }

    private static func ipv4String(from addr: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let addr else { return nil }
        var copy = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    private static func ipv6String(from addr: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let addr else { return nil }
        var copy = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &copy.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    private static func isRoutableIPv4(_ host: String) -> Bool {
        !(host.hasPrefix("169.254.") || host.hasPrefix("127.") || host == "0.0.0.0")
    }

    private static func isRoutableIPv6(_ host: String) -> Bool {
        let h = host.lowercased()
        return !(h.hasPrefix("fe80:") || h == "::1")
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

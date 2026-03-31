import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.trackball-watch.watch", category: "WatchUDP")

/// Direct UDP transport from Apple Watch to Desktop host.
/// Port of iPhone's UDPRelay, adapted for watchOS (@MainActor, no UIApplication bg tasks).
@MainActor
final class WatchUDPTransport {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case waiting(String)
        case failed(String)
        case cancelled
    }

    var onConfigPacket: ((UInt8, UInt8) -> Void)?
    var onStateFeedback: ((Bool, Double, Double) -> Void)?
    var onStateChanged: ((State) -> Void)?

    private(set) var state: State = .idle
    var isReady: Bool { state == .ready }

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.trackball.watch.udp", qos: .userInteractive)
    private var pendingOutbound: [Data] = []
    private let maxPending = 64
    private var handshakeSeq: UInt16 = 0

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() {
        guard connection == nil else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // Force direct Wi-Fi — prohibit BT relay through iPhone (.other interface)
        params.prohibitedInterfaceTypes = [.cellular, .other, .loopback, .wiredEthernet]
        let conn = NWConnection(to: endpoint, using: params)
        let h = host, p = port
        log.info("Connecting UDP → \(h, privacy: .public):\(p, privacy: .public)")

        conn.stateUpdateHandler = { [weak self] cs in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch cs {
                case .setup, .preparing:
                    self.updateState(.connecting)
                case .ready:
                    log.info("UDP ready → \(h, privacy: .public):\(p, privacy: .public)")
                    self.updateState(.ready)
                    if let conn = self.connection {
                        let hs = self.buildHandshake()
                        self.queue.async { conn.send(content: hs, completion: .contentProcessed { _ in }) }
                        self.receiveLoop()
                        self.flushPending()
                    }
                case .failed(let err):
                    log.error("UDP failed: \(err, privacy: .public)")
                    self.pendingOutbound.removeAll()
                    self.updateState(.failed(err.localizedDescription))
                case .waiting(let err):
                    log.warning("UDP waiting: \(err, privacy: .public)")
                    self.updateState(.waiting(err.localizedDescription))
                case .cancelled:
                    self.pendingOutbound.removeAll()
                    self.updateState(.cancelled)
                @unknown default:
                    break
                }
            }
        }
        conn.start(queue: queue)
        connection = conn
        updateState(.connecting)
    }

    func send(_ data: Data) {
        guard state != .cancelled else { return }
        if state == .ready, let conn = connection {
            queue.async { conn.send(content: data, completion: .contentProcessed { _ in }) }
        } else if case .connecting = state {
            // Buffer packets until transport is ready
            if pendingOutbound.count >= maxPending {
                pendingOutbound.removeFirst(pendingOutbound.count - maxPending + 1)
            }
            pendingOutbound.append(data)
        }
        // .failed / .waiting / .idle: drop (reconnect will re-establish session)
    }

    func cancel() {
        connection?.cancel()
        connection = nil
        pendingOutbound.removeAll()
        updateState(.cancelled)
    }

    // MARK: - Private

    private func updateState(_ s: State) {
        state = s
        onStateChanged?(s)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1500) { [weak self] data, _, _, error in
            if let data, data.count >= 9 {
                let packetType = data[2]
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if packetType == 0x12, data.count >= 10 {
                        self.onConfigPacket?(data[8], data[9])
                    } else if packetType == 0x13, data.count >= 13 {
                        let isCoasting = data[8] != 0
                        let vxFP = Int16(bitPattern: UInt16(data[9]) | (UInt16(data[10]) << 8))
                        let vyFP = Int16(bitPattern: UInt16(data[11]) | (UInt16(data[12]) << 8))
                        self.onStateFeedback?(isCoasting, Double(vxFP) / 64.0, Double(vyFP) / 64.0)
                    }
                }
            }
            if error == nil { Task { @MainActor [weak self] in self?.receiveLoop() } }
        }
    }

    private func flushPending() {
        guard let conn = connection, !pendingOutbound.isEmpty else { return }
        let batch = pendingOutbound
        pendingOutbound.removeAll(keepingCapacity: true)
        log.info("Flushing \(batch.count, privacy: .public) queued UDP packets")
        queue.async { batch.forEach { conn.send(content: $0, completion: .contentProcessed { _ in }) } }
    }

    private func buildHandshake() -> Data {
        handshakeSeq &+= 1
        var data = Data(capacity: 8)
        var seq = handshakeSeq.littleEndian
        withUnsafeBytes(of: &seq)  { data.append(contentsOf: $0) }
        data.append(0x10) // HANDSHAKE
        data.append(0)    // flags
        var ts = timestampUsLower32().littleEndian
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        return data
    }

    private func timestampUsLower32() -> UInt32 {
        let secs = Date().timeIntervalSince1970
        guard secs.isFinite, secs >= 0, secs <= Double(Int64.max) / 1_000_000.0 else { return 0 }
        let micros = Int64(secs * 1_000_000.0)
        guard micros >= 0 else { return 0 }
        return UInt32(truncatingIfNeeded: UInt64(micros))
    }
}

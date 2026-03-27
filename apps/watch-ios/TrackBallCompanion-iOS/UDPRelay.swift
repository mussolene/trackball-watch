import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.trackball-watch.app", category: "UDPRelay")

/// UDP client that sends TBP packets to the desktop host.
final class UDPRelay {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.trackball.udp", qos: .userInteractive)
    private var seq: UInt16 = 0

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(to: endpoint, using: params)
        let hostCopy = host, portCopy = port
        log.info("Connecting UDP to \(hostCopy, privacy: .public):\(portCopy, privacy: .public)")
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log.info("UDP ready → \(hostCopy, privacy: .public):\(portCopy, privacy: .public)")
                self?.sendHandshake()
            case .failed(let error):
                log.error("UDP failed: \(error, privacy: .public)")
            case .waiting(let error):
                log.warning("UDP waiting: \(error, privacy: .public)")
            default:
                log.debug("UDP state: \(String(describing: state), privacy: .public)")
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                log.error("send failed: \(error, privacy: .public)")
            }
        })
    }

    func cancel() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - TBP control packets

    /// Send a HANDSHAKE packet to initiate a session on the desktop.
    /// Packet format: [seq:u16 LE][type:u8=0x10][flags:u8=0][timestamp_us:u32 LE]
    func sendHandshake() {
        log.info("Sending HANDSHAKE")
        send(buildPacket(type: 0x10, payload: Data()))
    }

    /// Send a HEARTBEAT packet to keep the session alive.
    func sendHeartbeat() {
        log.debug("Sending HEARTBEAT")
        send(buildPacket(type: 0x11, payload: Data()))
    }

    // MARK: - Private

    private func buildPacket(type packetType: UInt8, payload: Data) -> Data {
        seq &+= 1
        let timestampUs = UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1_000_000))
        var data = Data(capacity: 8 + payload.count)
        data.appendLE(seq)
        data.append(packetType)
        data.append(0) // flags
        data.appendLE(timestampUs)
        data.append(payload)
        return data
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

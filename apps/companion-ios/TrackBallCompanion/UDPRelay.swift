import Foundation
import Network

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
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[UDPRelay] Connected to \(self?.host ?? ""):\(self?.port ?? 0)")
                self?.sendHandshake()
            case .failed(let error):
                print("[UDPRelay] Connection failed: \(error)")
            default:
                break
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    func cancel() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - TBP control packets

    /// Send a HANDSHAKE packet to initiate a session on the desktop.
    /// Packet format: [seq:u16 LE][type:u8=0x10][flags:u8=0][timestamp_us:u32 LE]
    func sendHandshake() {
        send(buildPacket(type: 0x10, payload: Data()))
    }

    /// Send a HEARTBEAT packet to keep the session alive.
    func sendHeartbeat() {
        send(buildPacket(type: 0x11, payload: Data()))
    }

    // MARK: - Private

    private func buildPacket(type packetType: UInt8, payload: Data) -> Data {
        seq &+= 1
        let timestampUs = UInt32(Date().timeIntervalSince1970 * 1_000_000) & 0xFFFF_FFFF
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

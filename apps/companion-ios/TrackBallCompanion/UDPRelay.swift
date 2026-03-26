import Foundation
import Network

/// UDP client that sends TBP packets to the desktop host.
final class UDPRelay {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.trackball.udp", qos: .userInteractive)

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
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[UDPRelay] Connected to \(self.host):\(self.port)")
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
}

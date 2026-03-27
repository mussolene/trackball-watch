import Foundation

/// TBP packet builder for the watch side.
/// Serializes packets to Data for transmission via WatchConnectivity.
///
/// Packet format: [seq:u16 LE][type:u8][flags:u8][timestamp_us:u32 LE][payload...]
struct TBPPacket {
    let type: PacketType
    let payload: Data

    enum PacketType: UInt8 {
        case touch     = 0x01
        case gesture   = 0x02
        case crown     = 0x03
        case handshake = 0x10
        case heartbeat = 0x11
        case ping      = 0x20
        case pong      = 0x21
    }

    enum GestureType: UInt8 {
        case tap       = 1
        case doubleTap = 2
        case longPress = 3
        case swipe     = 4
        case fling     = 5
        case pinch     = 6
    }

    // MARK: - Builders

    static func touch(touchId: UInt8, phase: TouchPhase, x: Int16, y: Int16, pressure: UInt8) -> TBPPacket {
        var payload = Data(capacity: 8)
        payload.append(touchId)
        payload.append(phase.rawValue)
        payload.appendLE(x)
        payload.appendLE(y)
        payload.append(pressure)
        payload.append(0) // padding
        return TBPPacket(type: .touch, payload: payload)
    }

    static func gesture(type: GestureType, fingers: UInt8, param1: Int16, param2: Int16) -> TBPPacket {
        var payload = Data(capacity: 6)
        payload.append(type.rawValue)
        payload.append(fingers)
        payload.appendLE(param1)
        payload.appendLE(param2)
        return TBPPacket(type: .gesture, payload: payload)
    }

    static func crown(delta: Int16, velocity: Int16) -> TBPPacket {
        var payload = Data(capacity: 4)
        payload.appendLE(delta)
        payload.appendLE(velocity)
        return TBPPacket(type: .crown, payload: payload)
    }

    static func heartbeat() -> TBPPacket {
        TBPPacket(type: .heartbeat, payload: Data())
    }

    // MARK: - Serialization

    /// Serialize the full packet with header.
    func serialize(seq: UInt16) -> Data {
        let timestampUs = Self.timestampUsLower32()
        var data = Data(capacity: 8 + payload.count)
        data.appendLE(seq)
        data.append(type.rawValue)
        data.append(0) // flags
        data.appendLE(timestampUs)
        data.append(payload)
        return data
    }

    /// Lower 32 bits of µs since 1970-01-01 (TBP header).
    /// Avoids `UInt64(Double)` trap: only convert to integer after finite + Int64 range checks.
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
}

// MARK: - Data helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Int16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

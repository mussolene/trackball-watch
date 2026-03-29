import Foundation

enum DebugTouchPhase: UInt8 {
    case began = 1
    case moved = 2
    case ended = 3
    case cancelled = 4
}

enum DebugGestureType: UInt8 {
    case tap = 1
    case doubleTap = 2
    case longPress = 3
    case swipe = 4
    case fling = 5
    case pinch = 6
}

struct DebugTBPPacket {
    private(set) var sequence: UInt16 = 0

    mutating func touch(phase: DebugTouchPhase, x: Int16, y: Int16, pressure: UInt8 = 0) -> Data {
        var payload = Data(capacity: 8)
        payload.append(0) // touchId
        payload.append(phase.rawValue)
        payload.appendLE(x)
        payload.appendLE(y)
        payload.append(pressure)
        payload.append(0)
        return buildPacket(type: 0x01, payload: payload)
    }

    mutating func fling(vx: Int16, vy: Int16) -> Data {
        var payload = Data(capacity: 6)
        payload.append(DebugGestureType.fling.rawValue)
        payload.append(1) // fingers
        payload.appendLE(vx)
        payload.appendLE(vy)
        return buildPacket(type: 0x02, payload: payload)
    }

    mutating func gesture(_ type: DebugGestureType, fingers: UInt8 = 1, param1: Int16 = 0, param2: Int16 = 0) -> Data {
        var payload = Data(capacity: 6)
        payload.append(type.rawValue)
        payload.append(fingers)
        payload.appendLE(param1)
        payload.appendLE(param2)
        return buildPacket(type: 0x02, payload: payload)
    }

    private mutating func buildPacket(type: UInt8, payload: Data) -> Data {
        sequence &+= 1
        let timestampUs = Self.timestampUsLower32()
        var data = Data(capacity: 8 + payload.count)
        data.appendLE(sequence)
        data.append(type)
        data.append(0)
        data.appendLE(timestampUs)
        data.append(payload)
        return data
    }

    private static func timestampUsLower32() -> UInt32 {
        let secs = Date().timeIntervalSince1970
        guard secs.isFinite, secs >= 0 else { return 0 }
        let microsDouble = secs * 1_000_000.0
        guard microsDouble.isFinite, microsDouble >= 0, microsDouble <= Double(Int64.max) else { return 0 }
        let micros = Int64(microsDouble)
        return UInt32(truncatingIfNeeded: UInt64(micros))
    }
}

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

import Foundation
import CoreGraphics
import simd

enum TrackballEngineTouchPhase {
    case began
    case moved
    case ended
    case cancelled
}

enum TrackballEngineEvent {
    case touch(phase: TrackballEngineTouchPhase, x: Int16, y: Int16, pressure: UInt8)
    case tap
    case doubleTap
    case longPress
    case fling(vx: Int16, vy: Int16)
}

struct TrackballCoastingFeedback {
    var active: Bool
    var vx: Double
    var vy: Double
}

@MainActor
final class TrackballInteractionEngine: ObservableObject {
    @Published private(set) var isDragging = false
    @Published private(set) var orientation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    @Published private(set) var angularVelocity: SIMD3<Double> = .zero
    @Published private(set) var virtualContactPoint: CGPoint = .zero
    @Published private(set) var pressureByte: UInt8 = 180

    private var stoppedCoastByTouch = false
    private var dragStart: CGPoint = .zero
    private var dragStartTime: Date = .distantPast
    private var lastDragPoint: CGPoint = .zero
    private var lastTick: Date = .now
    private var lastTapAt: Date = .distantPast
    private let virtualContactPacketScale: CGFloat = 32.0
    private let flingPacketScale: Double = 2.35
    private let tapMaxDistance: CGFloat = 8.0
    private let tapMaxDuration: TimeInterval = 0.28
    private let doubleTapWindow: TimeInterval = 0.32
    private let longPressMinDuration: TimeInterval = 0.48
    private let dragNoiseThreshold: CGFloat = 0.35

    func resetInteractionState() {
        isDragging = false
        angularVelocity = .zero
        virtualContactPoint = .zero
        pressureByte = 180
        stoppedCoastByTouch = false
    }

    var isCoasting: Bool {
        !isDragging && simd_length(angularVelocity) > 0.01
    }

    func handleDragChanged(
        location: CGPoint,
        diameter: CGFloat
    ) -> [TrackballEngineEvent] {
        let now = Date()
        let point = location

        if !isDragging {
            stoppedCoastByTouch = isCoasting
            isDragging = true
            dragStart = point
            dragStartTime = now
            lastDragPoint = point
            angularVelocity = .zero
            pressureByte = 180
            return [touchEvent(.began)]
        }

        let dx = point.x - lastDragPoint.x
        let dy = point.y - lastDragPoint.y
        lastDragPoint = point

        guard hypot(dx, dy) >= dragNoiseThreshold else {
            return []
        }

        applyDragRotation(dx: dx, dy: dy, diameter: diameter, location: point)
        virtualContactPoint.x = clampVirtualAxis(virtualContactPoint.x + dx)
        virtualContactPoint.y = clampVirtualAxis(virtualContactPoint.y + dy)

        let speed = hypot(dx, dy)
        pressureByte = UInt8(clamping: Int(min(255.0, max(1.0, 24.0 + speed * 5.5))))
        return [touchEvent(.moved)]
    }

    func handleDragEnded(
        location: CGPoint,
        diameter: CGFloat
    ) -> [TrackballEngineEvent] {
        defer { isDragging = false }

        let point = location
        let tapDistanceThreshold = max(tapMaxDistance, diameter * 0.08)
        let distance = hypot(point.x - dragStart.x, point.y - dragStart.y)
        let duration = Date().timeIntervalSince(dragStartTime)

        if stoppedCoastByTouch {
            stoppedCoastByTouch = false
            return [touchEvent(.ended)]
        }

        if distance < tapDistanceThreshold && duration >= longPressMinDuration {
            lastTapAt = .distantPast
            return [.longPress, touchEvent(.ended)]
        }

        if distance < tapDistanceThreshold && duration < tapMaxDuration {
            return tapEvents() + [touchEvent(.ended)]
        }

        let radius = Double(diameter / 2.0)
        if radius > 0 {
            let linearVX = CGFloat(angularVelocity.y * radius / 60.0)
            let linearVY = CGFloat(angularVelocity.x * radius / 60.0)
            if hypot(linearVX, linearVY) > 0.12 {
                return [touchEvent(.ended), flingEvent(vx: linearVX, vy: linearVY)]
            }
            angularVelocity = .zero
            return [touchEvent(.ended)]
        } else {
            angularVelocity = .zero
            return [touchEvent(.ended)]
        }
    }

    func tickPhysics(
        now: Date,
        ballDiameter: CGFloat,
        friction: Double,
        coastingFeedback: TrackballCoastingFeedback? = nil
    ) -> CGPoint {
        let dt = max(0.001, min(0.05, now.timeIntervalSince(lastTick)))
        lastTick = now
        guard !isDragging else { return .zero }

        if let feedback = coastingFeedback, feedback.active {
            let radius = Double(ballDiameter / 2.0)
            if radius > 0 {
                let target = SIMD3<Double>(
                    feedback.vy / radius * 60.0,
                    feedback.vx / radius * 60.0,
                    0
                )
                angularVelocity = angularVelocity * 0.7 + target * 0.3
            }
        }

        let speed = simd_length(angularVelocity)
        guard speed > 0.01 else {
            angularVelocity = .zero
            return .zero
        }

        let radius = Double(ballDiameter / 2.0)
        let delta = CGPoint(
            x: CGFloat(angularVelocity.y * radius * dt),
            y: CGFloat(angularVelocity.x * radius * dt)
        )
        virtualContactPoint.x = clampVirtualAxis(virtualContactPoint.x + delta.x)
        virtualContactPoint.y = clampVirtualAxis(virtualContactPoint.y + delta.y)

        let clampedFriction = max(0.001, min(0.999, friction))
        let damping = -log(clampedFriction) * 60.0
        angularVelocity *= exp(-damping * dt)

        let currentSpeed = simd_length(angularVelocity)
        if currentSpeed > 0.01 {
            let axis = angularVelocity / currentSpeed
            let deltaRotation = simd_quatd(angle: currentSpeed * dt, axis: axis)
            orientation = (deltaRotation * orientation).normalized
        } else {
            angularVelocity = .zero
        }

        return delta
    }

    func currentTouchEvent(phase: TrackballEngineTouchPhase, pressure: UInt8 = 0) -> TrackballEngineEvent {
        .touch(
            phase: phase,
            x: Int16(clamping: Int((virtualContactPoint.x * virtualContactPacketScale).rounded())),
            y: Int16(clamping: Int((virtualContactPoint.y * virtualContactPacketScale).rounded())),
            pressure: pressure
        )
    }

    private func touchEvent(_ phase: TrackballEngineTouchPhase) -> TrackballEngineEvent {
        .touch(
            phase: phase,
            x: Int16(clamping: Int((virtualContactPoint.x * virtualContactPacketScale).rounded())),
            y: Int16(clamping: Int((virtualContactPoint.y * virtualContactPacketScale).rounded())),
            pressure: 0
        )
    }

    private func tapEvents() -> [TrackballEngineEvent] {
        let now = Date()
        if now.timeIntervalSince(lastTapAt) < doubleTapWindow {
            lastTapAt = .distantPast
            return [.doubleTap]
        }
        lastTapAt = now
        return [.tap]
    }

    private func flingEvent(vx: CGFloat, vy: CGFloat) -> TrackballEngineEvent {
        let packetVX = Int16(clamping: Int((Double(vx) * flingPacketScale).rounded()))
        let packetVY = Int16(clamping: Int((Double(vy) * flingPacketScale).rounded()))
        return .fling(vx: packetVX, vy: packetVY)
    }

    private func clampVirtualAxis(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(min(value, CGFloat(Int16.max)), CGFloat(Int16.min))
    }

    private func applyDragRotation(dx: CGFloat, dy: CGFloat, diameter: CGFloat, location: CGPoint) {
        let radius = Double(diameter / 2.0)
        guard radius > 0 else { return }

        let omegaX = Double(dy) / radius
        let omegaY = Double(dx) / radius
        let _ = location
        let omega = SIMD3<Double>(omegaX, omegaY, 0)
        let angle = simd_length(omega)
        guard angle > 1e-6 else { return }

        let deltaRotation = simd_quatd(angle: angle, axis: omega / angle)
        orientation = (deltaRotation * orientation).normalized
        angularVelocity = omega * 60.0
    }
}

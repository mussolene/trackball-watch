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
    private var velocityHistory: [(time: Date, point: CGPoint)] = []

    private let velocityWindowSec: Double = 0.10
    private let virtualContactPacketScale: CGFloat = 32.0
    private let flingPacketScale: Double = 2.35
    private let tapMaxDistance: CGFloat = 8.0
    private let tapMaxDuration: TimeInterval = 0.28
    private let doubleTapWindow: TimeInterval = 0.32
    private let longPressMinDuration: TimeInterval = 0.48

    func resetInteractionState() {
        isDragging = false
        angularVelocity = .zero
        virtualContactPoint = .zero
        pressureByte = 180
        stoppedCoastByTouch = false
        velocityHistory.removeAll()
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
            virtualContactPoint = .zero
            velocityHistory.removeAll()
            velocityHistory.append((time: now, point: point))
            return [touchEvent(.began)]
        }

        let dx = point.x - lastDragPoint.x
        let dy = point.y - lastDragPoint.y
        lastDragPoint = point

        velocityHistory.append((time: now, point: point))
        if velocityHistory.count > 12 {
            velocityHistory.removeFirst()
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
            let angularFlingVX = CGFloat(angularVelocity.y * radius / 60.0)
            let angularFlingVY = CGFloat(angularVelocity.x * radius / 60.0)
            let sampledFling = computeFlingVelocity()
            let pressureScale = CGFloat(max(0.70, min(2.60, Double(pressureByte) / 104.0)))
            let scaledSampledVX = sampledFling.vx * pressureScale
            let scaledSampledVY = sampledFling.vy * pressureScale
            let scaledAngularVX = angularFlingVX * pressureScale * 1.45
            let scaledAngularVY = angularFlingVY * pressureScale * 1.45
            let scaledVX = preferredFlingVelocity(sampled: scaledSampledVX, angular: scaledAngularVX)
            let scaledVY = preferredFlingVelocity(sampled: scaledSampledVY, angular: scaledAngularVY)

            angularVelocity = SIMD3<Double>(
                Double(scaledVY) / radius * 60.0,
                Double(scaledVX) / radius * 60.0,
                0
            )

            return [touchEvent(.ended), flingEvent(vx: scaledVX, vy: scaledVY)]
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
        let omegaZ = zSpin(
            location: location,
            dx: dx,
            dy: dy,
            center: CGPoint(x: diameter / 2.0, y: diameter / 2.0),
            radius: CGFloat(radius)
        )
        let omega = SIMD3<Double>(omegaX, omegaY, omegaZ)
        let angle = simd_length(omega)
        guard angle > 1e-6 else { return }

        let deltaRotation = simd_quatd(angle: angle, axis: omega / angle)
        orientation = (deltaRotation * orientation).normalized
        angularVelocity = omega * 60.0
    }

    private func zSpin(
        location: CGPoint,
        dx: CGFloat,
        dy: CGFloat,
        center: CGPoint,
        radius: CGFloat
    ) -> Double {
        let rx = Double(location.x - center.x) / Double(radius)
        let ry = Double(location.y - center.y) / Double(radius)
        guard rx * rx + ry * ry < 0.85 * 0.85 else { return 0 }
        return (rx * Double(dy) - ry * Double(dx)) / Double(radius) * 0.4
    }

    private func computeFlingVelocity() -> (vx: CGFloat, vy: CGFloat) {
        let now = Date()
        let window = velocityHistory.filter { now.timeIntervalSince($0.time) < velocityWindowSec }
        guard window.count >= 2 else { return (0, 0) }

        var sumWeights = 0.0
        var weightedVX = 0.0
        var weightedVY = 0.0

        for index in 1..<window.count {
            let dt = window[index].time.timeIntervalSince(window[index - 1].time)
            guard dt > 1e-4 else { continue }

            let age = now.timeIntervalSince(window[index].time)
            let weight = exp(-age * 20.0)
            weightedVX += weight * Double(window[index].point.x - window[index - 1].point.x) / dt
            weightedVY += weight * Double(window[index].point.y - window[index - 1].point.y) / dt
            sumWeights += weight
        }

        guard sumWeights > 0 else { return (0, 0) }
        return (
            CGFloat(weightedVX / sumWeights / 60.0),
            CGFloat(weightedVY / sumWeights / 60.0)
        )
    }

    private func preferredFlingVelocity(sampled: CGFloat, angular: CGFloat) -> CGFloat {
        let sampledMagnitude = abs(sampled)
        let angularMagnitude = abs(angular)
        if angularMagnitude > sampledMagnitude * 1.25 {
            return angular
        }
        if sampledMagnitude > angularMagnitude * 1.25 {
            return sampled
        }
        return sampled * 0.35 + angular * 0.65
    }
}

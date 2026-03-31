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
    /// Contact point of the ball on the infinite virtual plane (screen analog); drives TBP x/y.
    @Published private(set) var virtualContactPoint: CGPoint = .zero
    @Published private(set) var pressureByte: UInt8 = 180

    private var stoppedCoastByTouch = false
    private var dragStart: CGPoint = .zero
    private var dragStartTime: Date = .distantPast
    private var lastDragPoint: CGPoint = .zero
    /// Last time a drag sample passed the noise gate and updated ω (rolling).
    private var lastRollingDragEventTime: Date = .distantPast
    private var lastOmegaSampleTime: Date = .distantPast
    private var lastTick: Date = .now
    private var lastTapAt: Date = .distantPast
    private let virtualContactPacketScale: CGFloat = 96.0

    /// Keep `x * virtualContactPacketScale` within Int16 range for TBP payloads.
    private var maxVirtualContact: CGFloat {
        CGFloat(Int16.max) / virtualContactPacketScale
    }
    private let flingPacketScale: Double = 2.35
    private let tapMaxDistance: CGFloat = 8.0
    private let tapMaxDuration: TimeInterval = 0.28
    private let doubleTapWindow: TimeInterval = 0.32
    private let longPressMinDuration: TimeInterval = 0.48
    /// Sub-point noise; `lastDragPoint` is only advanced when movement meets this (avoids host desync).
    private let dragNoiseThreshold: CGFloat = 0.22
    private let cursorMotionGain: Double = 2.4
    private let dragAngularVelocityBlend: Double = 0.35

    func resetInteractionState() {
        isDragging = false
        angularVelocity = .zero
        virtualContactPoint = .zero
        pressureByte = 180
        stoppedCoastByTouch = false
        lastDragPoint = .zero
        dragStart = .zero
        lastRollingDragEventTime = .distantPast
        lastOmegaSampleTime = .distantPast
    }

    var isCoasting: Bool {
        !isDragging && simd_length(angularVelocity) > 0.01
    }

    /// Pure rolling on a plane:
    /// the ball is visually stationary on screen while its contact point on the virtual screen-plane moves.
    /// The sphere orientation is advanced by the corresponding no-slip rolling rotation.
    func handleDragChanged(
        location: CGPoint,
        sphereCenter: CGPoint,
        sphereDiameter: CGFloat
    ) -> [TrackballEngineEvent] {
        let now = Date()
        let point = location
        let radius = Double(sphereDiameter / 2)

        if !isDragging {
            stoppedCoastByTouch = isCoasting
            isDragging = true
            dragStart = point
            dragStartTime = now
            lastDragPoint = point
            angularVelocity = .zero
            pressureByte = 180
            virtualContactPoint = .zero
            lastTick = now
            lastOmegaSampleTime = now
            _ = sphereCenter
            return [touchEvent(.began)]
        }

        let dx = point.x - lastDragPoint.x
        let dy = point.y - lastDragPoint.y

        guard hypot(dx, dy) >= dragNoiseThreshold else {
            return []
        }

        lastDragPoint = point
        lastRollingDragEventTime = now

        let dt = max(1e-4, min(0.25, now.timeIntervalSince(lastOmegaSampleTime)))
        lastOmegaSampleTime = now
        let measuredAngularVelocity = angularVelocityFromPlaneDisplacement(
            dx: Double(dx),
            dy: Double(dy),
            radius: radius,
            dt: dt
        )
        if simd_length(angularVelocity) > 1e-4 {
            angularVelocity = angularVelocity * (1.0 - dragAngularVelocityBlend)
                + measuredAngularVelocity * dragAngularVelocityBlend
        } else {
            angularVelocity = measuredAngularVelocity
        }

        let stepRotation = rotationFromPlaneDisplacement(dx: Double(dx), dy: Double(dy), radius: radius)
        orientation = simd_normalize(stepRotation * orientation)
        virtualContactPoint.x = clampVirtualAxis(virtualContactPoint.x + dx * cursorMotionGain)
        virtualContactPoint.y = clampVirtualAxis(virtualContactPoint.y + dy * cursorMotionGain)

        let speed = hypot(dx, dy)
        pressureByte = UInt8(clamping: Int(min(255.0, max(1.0, 24.0 + speed * 5.5))))
        return [touchEvent(.moved)]
    }

    func handleDragEnded(
        location: CGPoint,
        sphereDiameter: CGFloat
    ) -> [TrackballEngineEvent] {
        defer { isDragging = false }

        let point = location
        let tapDistanceThreshold = max(tapMaxDistance, sphereDiameter * 0.08)
        let distance = hypot(point.x - dragStart.x, point.y - dragStart.y)
        let duration = Date().timeIntervalSince(dragStartTime)

        if stoppedCoastByTouch {
            stoppedCoastByTouch = false
            // Touch-down while coasting stopped inertia; short lift-off can still be a click.
            let tapDistanceThreshold = max(tapMaxDistance, sphereDiameter * 0.08)
            let distance = hypot(point.x - dragStart.x, point.y - dragStart.y)
            let duration = Date().timeIntervalSince(dragStartTime)
            if distance < tapDistanceThreshold && duration < tapMaxDuration {
                return tapEvents() + [touchEvent(.ended)]
            }
            return [touchEvent(.ended)]
        }

        if distance < tapDistanceThreshold && duration >= longPressMinDuration {
            lastTapAt = .distantPast
            return [.longPress, touchEvent(.ended)]
        }

        if distance < tapDistanceThreshold && duration < tapMaxDuration {
            return tapEvents() + [touchEvent(.ended)]
        }

        let radius = Double(sphereDiameter / 2.0)
        if radius > 0 {
            // Plane velocity from rolling in UIKit coordinates: v_x = ω_y R, v_y = ω_x R.
            let linearVX = CGFloat(angularVelocity.y * radius * cursorMotionGain)
            let linearVY = CGFloat(angularVelocity.x * radius * cursorMotionGain)
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

        // During drag, contact movement is integrated directly in handleDragChanged so that
        // cursor movement stays exactly in lockstep with visible sphere rotation.
        if isDragging {
            if now.timeIntervalSince(lastRollingDragEventTime) > 0.08 {
                angularVelocity = .zero
            }
            return .zero
        }

        if let feedback = coastingFeedback, feedback.active {
            let radius = Double(ballDiameter / 2.0)
            if radius > 0 {
                let target = SIMD3<Double>(
                    feedback.vy / (radius * cursorMotionGain),
                    feedback.vx / (radius * cursorMotionGain),
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
        let delta = planeDisplacementFromOmega(angularVelocity, radius: radius, dt: dt)
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

    func currentTouchEvent(phase: TrackballEngineTouchPhase, pressure: UInt8? = nil) -> TrackballEngineEvent {
        let p: UInt8
        if let pressure {
            p = pressure
        } else {
            switch phase {
            case .began, .moved:
                p = pressureByte
            case .ended, .cancelled:
                p = 0
            }
        }
        return .touch(
            phase: phase,
            x: Int16(clamping: Int((virtualContactPoint.x * virtualContactPacketScale).rounded())),
            y: Int16(clamping: Int((virtualContactPoint.y * virtualContactPacketScale).rounded())),
            pressure: p
        )
    }

    private func touchEvent(_ phase: TrackballEngineTouchPhase) -> TrackballEngineEvent {
        let pressure: UInt8
        switch phase {
        case .began:
            pressure = pressureByte
        case .moved:
            pressure = pressureByte
        case .ended, .cancelled:
            pressure = 0
        }
        return .touch(
            phase: phase,
            x: Int16(clamping: Int((virtualContactPoint.x * virtualContactPacketScale).rounded())),
            y: Int16(clamping: Int((virtualContactPoint.y * virtualContactPacketScale).rounded())),
            pressure: pressure
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
        return max(min(value, maxVirtualContact), -maxVirtualContact)
    }

    /// No-slip rolling on the virtual screen-plane in UIKit coordinates:
    /// screen displacement `(dx, dy)` maps to angular velocity `(ωx, ωy, 0)`
    /// where `v = (ωy R, ωx R)`.
    private func angularVelocityFromPlaneDisplacement(dx: Double, dy: Double, radius: Double, dt: Double) -> SIMD3<Double> {
        guard radius > 1e-6, dt > 1e-6 else { return .zero }
        return SIMD3<Double>(
            dy / (radius * dt),
            dx / (radius * dt),
            0
        )
    }

    private func rotationFromPlaneDisplacement(dx: Double, dy: Double, radius: Double) -> simd_quatd {
        guard radius > 1e-6 else {
            return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let angle = hypot(dx, dy) / radius
        guard angle > 1e-9 else {
            return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let axis = simd_normalize(SIMD3<Double>(dy, dx, 0))
        return simd_quatd(angle: angle, axis: axis)
    }

    /// Rolling on the virtual screen-plane: d(contact)/dt = (ω_y R, ω_x R) in UIKit.
    private func planeDisplacementFromOmega(_ omega: SIMD3<Double>, radius: Double, dt: Double) -> CGPoint {
        CGPoint(
            x: CGFloat(omega.y * radius * dt * cursorMotionGain),
            y: CGFloat(omega.x * radius * dt * cursorMotionGain)
        )
    }
}

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
    private var lastAcceptedDragDelta: CGPoint = .zero
    private var lastAcceptedDragDt: Double = 1.0 / 60.0
    private var packetContactX: Int32 = 0
    private var packetContactY: Int32 = 0
    private var packetFractionX: CGFloat = 0
    private var packetFractionY: CGFloat = 0
    /// Virtual-plane velocity of contact point (points per second).
    private var coastingPlaneVelocity: CGPoint = .zero
    /// Last time a drag sample passed the noise gate and updated ω (rolling).
    private var lastRollingDragEventTime: Date = .distantPast
    private var lastOmegaSampleTime: Date = .distantPast
    private var lastTick: Date = .now
    private var lastTapAt: Date = .distantPast
    /// Scale factor from virtual-plane units to TBP Int16 range.
    /// Smaller value → больше виртуальный стол до насыщения Int16.
    private let virtualContactPacketScale: CGFloat = 32.0

    private let tapMaxDistance: CGFloat = 8.0
    private let tapMaxDuration: TimeInterval = 0.28
    private let doubleTapWindow: TimeInterval = 0.32
    private let longPressMinDuration: TimeInterval = 0.48
    /// Sub-point noise; `lastDragPoint` is only advanced when movement meets this (avoids host desync).
    private let dragNoiseThreshold: CGFloat = 0.22
    private let cursorMotionGain: Double = 2.4
    private let nominalBallDiameter: Double = 300.0
    private let dragAngularVelocityBlend: Double = 0.35
    private let dragPlaneVelocityBlend: Double = 0.35
    private let releaseMotionIdleTimeout: TimeInterval = 0.09
    /// Keep per-packet axis step safely below wrap ambiguity threshold (Int16 ring).
    private let maxPacketDeltaPerTickRaw: CGFloat = 12_000

    func resetInteractionState() {
        isDragging = false
        angularVelocity = .zero
        virtualContactPoint = .zero
        pressureByte = 180
        stoppedCoastByTouch = false
        lastDragPoint = .zero
        lastAcceptedDragDelta = .zero
        lastAcceptedDragDt = 1.0 / 60.0
        packetContactX = 0
        packetContactY = 0
        packetFractionX = 0
        packetFractionY = 0
        coastingPlaneVelocity = .zero
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
        let effectiveCursorGain = cursorGain(forBallDiameter: Double(sphereDiameter))

        if !isDragging {
            stoppedCoastByTouch = isCoasting
            isDragging = true
            dragStart = point
            dragStartTime = now
            lastDragPoint = point
            lastAcceptedDragDelta = .zero
            lastAcceptedDragDt = 1.0 / 60.0
            coastingPlaneVelocity = .zero
            angularVelocity = .zero
            pressureByte = 180
            virtualContactPoint = .zero
            packetContactX = 0
            packetContactY = 0
            packetFractionX = 0
            packetFractionY = 0
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
        lastAcceptedDragDelta = CGPoint(x: dx, y: dy)
        lastAcceptedDragDt = dt
        let measuredPlaneVelocity = CGPoint(
            x: (dx * effectiveCursorGain) / dt,
            y: (dy * effectiveCursorGain) / dt
        )
        if hypot(coastingPlaneVelocity.x, coastingPlaneVelocity.y) > 1e-4 {
            coastingPlaneVelocity = CGPoint(
                x: coastingPlaneVelocity.x * (1.0 - dragPlaneVelocityBlend) + measuredPlaneVelocity.x * dragPlaneVelocityBlend,
                y: coastingPlaneVelocity.y * (1.0 - dragPlaneVelocityBlend) + measuredPlaneVelocity.y * dragPlaneVelocityBlend
            )
        } else {
            coastingPlaneVelocity = measuredPlaneVelocity
        }
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
        let cursorDelta = CGPoint(x: dx * effectiveCursorGain, y: dy * effectiveCursorGain)
        virtualContactPoint.x = accumulateVirtualAxis(virtualContactPoint.x, delta: cursorDelta.x)
        virtualContactPoint.y = accumulateVirtualAxis(virtualContactPoint.y, delta: cursorDelta.y)
        advancePacketContact(by: cursorDelta)

        let speed = hypot(dx, dy)
        pressureByte = UInt8(clamping: Int(min(255.0, max(1.0, 24.0 + speed * 5.5))))
        return [touchEvent(.moved)]
    }

    func handleDragEnded(
        location: CGPoint,
        sphereDiameter: CGFloat
    ) -> [TrackballEngineEvent] {
        defer { isDragging = false }

        let now = Date()
        let point = location
        let tapDistanceThreshold = max(tapMaxDistance, sphereDiameter * 0.08)
        let distance = hypot(point.x - dragStart.x, point.y - dragStart.y)
        let duration = now.timeIntervalSince(dragStartTime)

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
        let effectiveCursorGain = cursorGain(forBallDiameter: Double(sphereDiameter))
        let idleSinceLastRolling = now.timeIntervalSince(lastRollingDragEventTime)
        if idleSinceLastRolling > releaseMotionIdleTimeout {
            angularVelocity = .zero
            coastingPlaneVelocity = .zero
            return [touchEvent(.ended)]
        }
        if radius > 0 {
            if hypot(coastingPlaneVelocity.x, coastingPlaneVelocity.y) <= 0.12,
               hypot(lastAcceptedDragDelta.x, lastAcceptedDragDelta.y) >= dragNoiseThreshold {
                // Start coast from the latest accepted rolling direction, not from lift-off noise.
                angularVelocity = angularVelocityFromPlaneDisplacement(
                    dx: Double(lastAcceptedDragDelta.x),
                    dy: Double(lastAcceptedDragDelta.y),
                    radius: radius,
                    dt: max(1e-4, min(0.25, lastAcceptedDragDt))
                )
                coastingPlaneVelocity = CGPoint(
                    x: (lastAcceptedDragDelta.x * effectiveCursorGain) / max(1e-4, min(0.25, lastAcceptedDragDt)),
                    y: (lastAcceptedDragDelta.y * effectiveCursorGain) / max(1e-4, min(0.25, lastAcceptedDragDt))
                )
            }

            // Recover terminal velocity from the final drag segment in case the last onChanged
            // sample was skipped by gesture/event timing right before lift-off.
            let endDX = point.x - lastDragPoint.x
            let endDY = point.y - lastDragPoint.y
            let endDistance = hypot(endDX, endDY)
            let sampleAge = now.timeIntervalSince(lastOmegaSampleTime)
            // Ignore tiny lift-off jitter; only recover if the last real drag sample is stale.
            if hypot(coastingPlaneVelocity.x, coastingPlaneVelocity.y) <= 0.12,
               hypot(lastAcceptedDragDelta.x, lastAcceptedDragDelta.y) < dragNoiseThreshold,
               endDistance >= dragNoiseThreshold,
               sampleAge > 0.012 {
                let endDt = max(1e-4, min(0.25, now.timeIntervalSince(lastOmegaSampleTime)))
                let terminalOmega = angularVelocityFromPlaneDisplacement(
                    dx: Double(endDX),
                    dy: Double(endDY),
                    radius: radius,
                    dt: endDt
                )
                if simd_length(angularVelocity) > 1e-4 {
                    angularVelocity = angularVelocity * (1.0 - dragAngularVelocityBlend)
                        + terminalOmega * dragAngularVelocityBlend
                } else {
                    angularVelocity = terminalOmega
                }
                coastingPlaneVelocity = CGPoint(
                    x: (endDX * effectiveCursorGain) / endDt,
                    y: (endDY * effectiveCursorGain) / endDt
                )
            }

            let linearVX = coastingPlaneVelocity.x
            let linearVY = coastingPlaneVelocity.y
            if hypot(linearVX, linearVY) > 0.12 {
                // Keep streaming virtual contact coordinates during coast.
                // The finger is no longer touching, but the ball is still rolling on the plane.
                return []
            }
            angularVelocity = .zero
            coastingPlaneVelocity = .zero
            return [touchEvent(.ended)]
        } else {
            angularVelocity = .zero
            coastingPlaneVelocity = .zero
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
            return .zero
        }

        if let feedback = coastingFeedback, feedback.active {
            let radius = Double(ballDiameter / 2.0)
            let effectiveCursorGain = cursorGain(forBallDiameter: Double(ballDiameter))
            if radius > 0 {
                let target = SIMD3<Double>(
                    feedback.vy / (radius * effectiveCursorGain),
                    feedback.vx / (radius * effectiveCursorGain),
                    0
                )
                angularVelocity = angularVelocity * 0.7 + target * 0.3
            }
        }

        let planeSpeed = hypot(coastingPlaneVelocity.x, coastingPlaneVelocity.y)
        guard planeSpeed > 0.01 else {
            coastingPlaneVelocity = .zero
            angularVelocity = .zero
            return .zero
        }

        let radius = Double(ballDiameter / 2.0)
        let effectiveCursorGain = cursorGain(forBallDiameter: Double(ballDiameter))
        var delta = CGPoint(
            x: coastingPlaneVelocity.x * dt,
            y: coastingPlaneVelocity.y * dt
        )
        delta = clampDeltaForPacketContinuity(delta)
        virtualContactPoint.x = accumulateVirtualAxis(virtualContactPoint.x, delta: delta.x)
        virtualContactPoint.y = accumulateVirtualAxis(virtualContactPoint.y, delta: delta.y)
        advancePacketContact(by: delta)

        let clampedFriction = max(0.001, min(0.999, friction))
        let damping = -log(clampedFriction) * 60.0
        let decay = exp(-damping * dt)
        coastingPlaneVelocity.x *= decay
        coastingPlaneVelocity.y *= decay

        if radius > 1e-6 {
            angularVelocity = SIMD3<Double>(
                Double(coastingPlaneVelocity.y) / (radius * effectiveCursorGain),
                Double(coastingPlaneVelocity.x) / (radius * effectiveCursorGain),
                0
            )
        } else {
            angularVelocity = .zero
        }

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
            x: packetContactAxis(packetContactX),
            y: packetContactAxis(packetContactY),
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
            x: packetContactAxis(packetContactX),
            y: packetContactAxis(packetContactY),
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

    private func accumulateVirtualAxis(_ value: CGFloat, delta: CGFloat) -> CGFloat {
        let next = value + delta
        guard next.isFinite else { return 0 }
        return next
    }

    private func advancePacketContact(by delta: CGPoint) {
        packetContactX = advancePacketAxis(
            packetContactX,
            fraction: &packetFractionX,
            deltaRaw: delta.x * virtualContactPacketScale
        )
        packetContactY = advancePacketAxis(
            packetContactY,
            fraction: &packetFractionY,
            deltaRaw: delta.y * virtualContactPacketScale
        )
    }

    private func advancePacketAxis(_ current: Int32, fraction: inout CGFloat, deltaRaw: CGFloat) -> Int32 {
        guard deltaRaw.isFinite else {
            fraction = 0
            return current
        }

        let total = fraction + deltaRaw
        let step = Int32(total.rounded(.towardZero))
        fraction = total - CGFloat(step)
        return current &+ step
    }

    private func packetContactAxis(_ value: Int32) -> Int16 {
        Int16(truncatingIfNeeded: value)
    }

    private func cursorGain(forBallDiameter diameter: Double) -> CGFloat {
        let safeDiameter = max(1.0, diameter)
        return CGFloat(cursorMotionGain * (safeDiameter / nominalBallDiameter))
    }

    private func clampDeltaForPacketContinuity(_ delta: CGPoint) -> CGPoint {
        let maxAxisStep = maxPacketDeltaPerTickRaw / virtualContactPacketScale
        return CGPoint(
            x: max(min(delta.x, maxAxisStep), -maxAxisStep),
            y: max(min(delta.y, maxAxisStep), -maxAxisStep)
        )
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

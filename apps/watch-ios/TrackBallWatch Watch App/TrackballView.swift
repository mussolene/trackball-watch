import SwiftUI
import WatchKit
import Combine
import simd

/// Virtual trackball for trackball mode.
/// Sphere sits bottom-trailing for thumb reach; coast damping matches desktop (`trackballFriction` from CONFIG).
struct TrackballView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    @State private var dragStart: CGPoint = .zero
    @State private var dragStartTime: Date = .distantPast
    @State private var isDragging = false
    /// Quaternion representing current 3D orientation of the ball.
    @State private var orientation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    /// Angular velocity in rad/s (world space). Drives coasting animation.
    @State private var angularVelocity: SIMD3<Double> = .zero
    @State private var lastDragPoint: CGPoint = .zero
    @State private var lastTick: Date = .now
    @State private var lastTapAt: Date = .distantPast
    /// 1–255 from drag speed; forwarded in TOUCH for host gain.
    @State private var pressureByte: UInt8 = 180
    /// Virtual contact point of the ball against the desktop surface.
    /// This stays in local ball-surface units; the host maps it to screen pixels.
    @State private var virtualContactPoint: CGPoint = .zero
    /// Recent touch positions for accurate fling velocity estimation.
    @State private var velocityHistory: [(time: Date, point: CGPoint)] = []
    private let velocityWindowSec: Double = 0.08
    /// Fixed-point scale for streaming sub-point trackball motion to the host.
    private let virtualContactPacketScale: CGFloat = 32.0

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height) * 0.56
            ZStack(alignment: .bottomTrailing) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                ballView(d: d)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .onReceive(tick) { now in tickPhysics(now: now, ballDiameter: d) }
        }
    }

    // MARK: - Ball view

    @ViewBuilder
    private func ballView(d: CGFloat) -> some View {
        SceneKitSphereView(diameter: d, orientation: orientation, isDragging: isDragging)
            .frame(width: d, height: d)
            .shadow(
                color: .black.opacity(isDragging ? 0.72 : 0.58),
                radius: isDragging ? 12 : 10,
                x: 2, y: isDragging ? 12 : 10
            )
            .padding(8)
            .contentShape(Circle())
            .accessibilityLabel("Trackball")
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in onDragChanged(v, diameter: d) }
                    .onEnded   { v in onDragEnded(v, diameter: d) }
            )
    }

    // MARK: - Drag handlers

    private func onDragChanged(_ value: DragGesture.Value, diameter: CGFloat) {
        if !isDragging {
            isDragging = true
            dragStart = value.location
            dragStartTime = .now
            lastDragPoint = value.location
            angularVelocity = .zero
            pressureByte = 180
            virtualContactPoint = .zero
            velocityHistory.removeAll()
            velocityHistory.append((time: .now, point: value.location))
            sessionManager.send(virtualTouchPacket(.began))
            WKInterfaceDevice.current().play(.start)
        } else {
            let dx = value.location.x - lastDragPoint.x
            let dy = value.location.y - lastDragPoint.y
            lastDragPoint = value.location

            velocityHistory.append((time: .now, point: value.location))
            if velocityHistory.count > 12 { velocityHistory.removeFirst() }

            applyDragRotation(dx: dx, dy: dy, diameter: diameter, location: value.location)
            virtualContactPoint.x = clampVirtualAxis(virtualContactPoint.x + dx)
            virtualContactPoint.y = clampVirtualAxis(virtualContactPoint.y + dy)

            let speed = hypot(dx, dy)
            pressureByte = UInt8(clamping: Int(min(255.0, max(1.0, 24.0 + speed * 5.5))))
            sessionManager.send(virtualTouchPacket(.moved))
        }
    }

    private func onDragEnded(_ value: DragGesture.Value, diameter: CGFloat) {
        defer { isDragging = false }
        let dist = hypot(value.location.x - dragStart.x, value.location.y - dragStart.y)
        let dur  = Date().timeIntervalSince(dragStartTime)
        if dist < 8 && dur < 0.28 {
            handleTap()
            sessionManager.send(virtualTouchPacket(.ended))
            return
        }
        let (vx, vy) = computeFlingVelocity()
        let pScale = CGFloat(max(0.35, min(1.75, Double(pressureByte) / 128.0)))
        sendFling(vx: vx * pScale, vy: vy * pScale, diameter: diameter)
        sessionManager.send(virtualTouchPacket(.ended))

        let r = Double(diameter / 2.0)
        if r > 0 {
            angularVelocity = SIMD3<Double>( Double(vy * pScale) / r * 60.0,
                                            Double(vx * pScale) / r * 60.0,
                                            0)
        }
        WKInterfaceDevice.current().play(.directionUp)
    }

    // MARK: - Physics tick (60 Hz)

    private func tickPhysics(now: Date, ballDiameter: CGFloat) {
        let dt = max(0.001, min(0.05, now.timeIntervalSince(lastTick)))
        lastTick = now
        guard !isDragging else { return }

        // Soft-sync with desktop coasting velocity at ~10 Hz
        let fb = sessionManager.coastingState
        if fb.active {
            let r = Double(ballDiameter / 2.0)
            if r > 0 {
                let target = SIMD3<Double>( fb.vy / r * 60.0, fb.vx / r * 60.0, 0)
                angularVelocity = angularVelocity * 0.7 + target * 0.3
            }
        }

        let speed = simd_length(angularVelocity)
        guard speed > 0.01 else { angularVelocity = .zero; return }

        // Frame-rate-independent friction
        let friction = sessionManager.trackballFriction
        let k = -log(max(0.001, friction)) * 60.0
        angularVelocity *= exp(-k * dt)

        let s2 = simd_length(angularVelocity)
        if s2 > 0.01 {
            let axis  = angularVelocity / s2
            let dq    = simd_quatd(angle: s2 * dt, axis: axis)
            orientation = (dq * orientation).normalized
        } else {
            angularVelocity = .zero
        }
    }

    // MARK: - 3D Rotation

    private func applyDragRotation(dx: CGFloat, dy: CGFloat, diameter: CGFloat, location: CGPoint) {
        let r = Double(diameter / 2.0)
        guard r > 0 else { return }
        let omegaX =  Double(dy) / r
        let omegaY =  Double(dx) / r
        let omegaZ = zSpin(location: location, dx: dx, dy: dy,
                           center: CGPoint(x: diameter / 2, y: diameter / 2), radius: CGFloat(r))
        let omega = SIMD3<Double>(omegaX, omegaY, omegaZ)
        let angle = simd_length(omega)
        guard angle > 1e-6 else { return }
        let dq = simd_quatd(angle: angle, axis: omega / angle)
        orientation      = (dq * orientation).normalized
        angularVelocity  = omega * 60.0
    }

    /// Cross-product Z spin: drag across surface edge → rotation around view axis.
    private func zSpin(location: CGPoint, dx: CGFloat, dy: CGFloat,
                       center: CGPoint, radius: CGFloat) -> Double {
        let rx = Double(location.x - center.x) / Double(radius)
        let ry = Double(location.y - center.y) / Double(radius)
        guard rx * rx + ry * ry < 0.85 * 0.85 else { return 0 }
        return (rx * Double(dy) - ry * Double(dx)) / Double(radius) * 0.4
    }

    // MARK: - Fling Velocity

    /// Weighted velocity from recent touch history (points/frame @ 60 Hz).
    private func computeFlingVelocity() -> (vx: CGFloat, vy: CGFloat) {
        let now    = Date()
        let window = velocityHistory.filter { now.timeIntervalSince($0.time) < velocityWindowSec }
        guard window.count >= 2 else { return (0, 0) }
        var sumW = 0.0, sumWvx = 0.0, sumWvy = 0.0
        for i in 1..<window.count {
            let dt = window[i].time.timeIntervalSince(window[i - 1].time)
            guard dt > 1e-4 else { continue }
            let age = now.timeIntervalSince(window[i].time)
            let w   = exp(-age * 20.0)
            sumWvx += w * Double(window[i].point.x - window[i - 1].point.x) / dt
            sumWvy += w * Double(window[i].point.y - window[i - 1].point.y) / dt
            sumW   += w
        }
        guard sumW > 0 else { return (0, 0) }
        return (CGFloat(sumWvx / sumW / 60.0), CGFloat(sumWvy / sumW / 60.0))
    }

    // MARK: - Tap

    private func handleTap() {
        let now = Date()
        if now.timeIntervalSince(lastTapAt) < 0.32 {
            sessionManager.send(TBPPacket.gesture(type: .doubleTap, fingers: 1, param1: 0, param2: 0))
            WKInterfaceDevice.current().play(.success)
            lastTapAt = .distantPast
            return
        }
        lastTapAt = now
        sessionManager.send(TBPPacket.gesture(type: .tap, fingers: 1, param1: 0, param2: 0))
        WKInterfaceDevice.current().play(.click)
    }

    // MARK: - Packet helpers

    private func norm(_ v: CGFloat, size: CGFloat) -> Int16 {
        guard size > 0, v.isFinite else { return 0 }
        let t = Double(v / size) * 2.0 - 1.0
        return Int16(clamping: Int((t * 32767.0).rounded()))
    }

    private func clampVirtualAxis(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(min(value, CGFloat(Int16.max)), CGFloat(Int16.min))
    }

    private func touchPacket(_ phase: TouchPhase, pt: CGPoint, in size: CGSize) -> TBPPacket {
        TBPPacket.touch(touchId: 0, phase: phase,
                        x: norm(pt.x, size: size.width),
                        y: norm(pt.y, size: size.height),
                        pressure: pressureByte)
    }

    private func virtualTouchPacket(_ phase: TouchPhase) -> TBPPacket {
        TBPPacket.touch(
            touchId: 0,
            phase: phase,
            x: Int16(clamping: Int((virtualContactPoint.x * virtualContactPacketScale).rounded())),
            y: Int16(clamping: Int((virtualContactPoint.y * virtualContactPacketScale).rounded())),
            pressure: 0
        )
    }

    private func sendFling(vx: CGFloat, vy: CGFloat, diameter: CGFloat) {
        guard diameter > 0 else { return }
        let nx = Double(vx) * 1.5
        let ny = Double(vy) * 1.5
        let px = Int16(clamping: Int(max(min(nx, Double(Int16.max)), Double(Int16.min)).rounded()))
        let py = Int16(clamping: Int(max(min(ny, Double(Int16.max)), Double(Int16.min)).rounded()))
        sessionManager.send(TBPPacket.gesture(type: .fling, fingers: 1, param1: px, param2: py))
    }
}

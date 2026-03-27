import SwiftUI
import WatchKit
import Combine

/// Virtual trackball for trackball mode.
/// Sphere sits bottom-trailing for thumb reach; coast damping matches desktop (`trackballFriction` from CONFIG).
struct TrackballView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    @State private var dragStart: CGPoint = .zero
    @State private var dragStartTime: Date = .distantPast
    @State private var isDragging = false
    @State private var rotX: Double = 0
    @State private var rotY: Double = 0
    @State private var angularVX: Double = 0
    @State private var angularVY: Double = 0
    @State private var lastDragPoint: CGPoint = .zero
    @State private var lastTick: Date = .now
    @State private var lastTapAt: Date = .distantPast
    /// 1–255 from drag speed; forwarded in TOUCH for host gain (trackpad path may keep 0).
    @State private var pressureByte: UInt8 = 0

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let ballDiameter = min(geo.size.width, geo.size.height) * 0.56
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                KineticTrackballSphere(
                    diameter: ballDiameter,
                    rotX: rotX,
                    rotY: rotY,
                    isDragging: isDragging
                )
                    .animation(isDragging ? nil : .easeOut(duration: 0.35), value: rotX)
                    .animation(isDragging ? nil : .easeOut(duration: 0.35), value: rotY)
                    .frame(width: ballDiameter, height: ballDiameter)
                    .padding(8)
                    .contentShape(Circle())
                    .accessibilityLabel("Trackball")
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStart = value.location
                                    dragStartTime = .now
                                    lastDragPoint = value.location
                                    angularVX = 0
                                    angularVY = 0
                                    pressureByte = 180
                                    sendTouchBegan(value.location, in: CGSize(width: ballDiameter, height: ballDiameter))
                                    WKInterfaceDevice.current().play(.start)
                                } else {
                                    let dx = value.location.x - lastDragPoint.x
                                    let dy = value.location.y - lastDragPoint.y
                                    lastDragPoint = value.location
                                    rotY += dx * 0.9
                                    rotX += -dy * 0.9
                                    angularVY = Double(dx) * 20.0
                                    angularVX = Double(-dy) * 20.0
                                    let speed = hypot(dx, dy)
                                    pressureByte = UInt8(clamping: Int(min(255, max(1, 24 + speed * 5.5))))
                                    sendTouchMoved(value.location, in: CGSize(width: ballDiameter, height: ballDiameter))
                                }
                            }
                            .onEnded { value in
                                defer { isDragging = false }
                                let dragDist = hypot(
                                    value.location.x - dragStart.x,
                                    value.location.y - dragStart.y
                                )
                                let dragDuration = Date().timeIntervalSince(dragStartTime)
                                if dragDist < 8 && dragDuration < 0.28 {
                                    handleTap()
                                    sendTouchEnded(value.location, in: CGSize(width: ballDiameter, height: ballDiameter))
                                    return
                                }
                                let vx = value.predictedEndLocation.x - value.location.x
                                let vy = value.predictedEndLocation.y - value.location.y
                                let pScale = max(0.35, min(1.75, CGFloat(pressureByte) / 128.0))
                                sendFling(
                                    vx: vx * pScale,
                                    vy: vy * pScale,
                                    in: CGSize(width: ballDiameter, height: ballDiameter)
                                )
                                sendTouchEnded(value.location, in: CGSize(width: ballDiameter, height: ballDiameter))
                                angularVY += Double(vx) * 3.0 * Double(pScale)
                                angularVX += Double(-vy) * 3.0 * Double(pScale)
                                WKInterfaceDevice.current().play(.directionUp)
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .onReceive(tick) { now in
                let dt = max(0.0, min(0.05, now.timeIntervalSince(lastTick)))
                lastTick = now
                guard !isDragging else { return }
                guard angularVX != 0 || angularVY != 0 else { return }

                // Same as host `TrackballState::tick`: v *= friction once per ~60 Hz step.
                let friction = sessionManager.trackballFriction
                rotX += angularVX * dt
                rotY += angularVY * dt
                angularVX *= friction
                angularVY *= friction

                if abs(angularVX) < 0.4 { angularVX = 0 }
                if abs(angularVY) < 0.4 { angularVY = 0 }
            }
        }
    }

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

    private func normalize(_ v: CGFloat, size: CGFloat) -> Int16 {
        guard size > 0, v.isFinite else { return 0 }
        let t = (v / size) * 2.0 - 1.0
        let scaled = t * 32767.0
        let d = max(min(Double(scaled), Double(Int16.max)), Double(Int16.min))
        return Int16(clamping: Int(d.rounded()))
    }

    private func sendTouchBegan(_ pt: CGPoint, in size: CGSize) {
        let p = TBPPacket.touch(touchId: 0, phase: .began,
                                x: normalize(pt.x, size: size.width),
                                y: normalize(pt.y, size: size.height),
                                pressure: pressureByte)
        sessionManager.send(p)
    }

    private func sendTouchMoved(_ pt: CGPoint, in size: CGSize) {
        let p = TBPPacket.touch(touchId: 0, phase: .moved,
                                x: normalize(pt.x, size: size.width),
                                y: normalize(pt.y, size: size.height),
                                pressure: pressureByte)
        sessionManager.send(p)
    }

    private func sendTouchEnded(_ pt: CGPoint, in size: CGSize) {
        let p = TBPPacket.touch(touchId: 0, phase: .ended,
                                x: normalize(pt.x, size: size.width),
                                y: normalize(pt.y, size: size.height),
                                pressure: pressureByte)
        sessionManager.send(p)
    }

    private func sendFling(vx: CGFloat, vy: CGFloat, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let nx = Double(vx / size.width * 32767 * 2)
        let ny = Double(vy / size.height * 32767 * 2)
        let normVx = Int16(clamping: Int(max(min(nx, Double(Int16.max)), Double(Int16.min)).rounded()))
        let normVy = Int16(clamping: Int(max(min(ny, Double(Int16.max)), Double(Int16.min)).rounded()))
        let p = TBPPacket.gesture(type: .fling, fingers: 1, param1: normVx, param2: normVy)
        sessionManager.send(p)
    }
}

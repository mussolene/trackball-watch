import SwiftUI
import WatchKit

/// Virtual trackball for trackball mode.
/// Displays a red 3D-looking sphere; drag to spin and fling it.
struct TrackballView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager

    @State private var dragStart: CGPoint = .zero
    @State private var isDragging = false
    // Accumulated rotation offset for visual feedback
    @State private var rotX: Double = 0
    @State private var rotY: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Ball
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 1.0, green: 0.3, blue: 0.2),
                                Color(red: 0.6, green: 0.05, blue: 0.0)
                            ],
                            center: UnitPoint(x: 0.35, y: 0.3),
                            startRadius: 0,
                            endRadius: geo.size.width * 0.5
                        )
                    )
                    .overlay(
                        // Specular highlight
                        Ellipse()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: geo.size.width * 0.35, height: geo.size.width * 0.18)
                            .offset(x: -geo.size.width * 0.12, y: -geo.size.width * 0.18)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 6, x: 3, y: 4)
                    .rotation3DEffect(.degrees(rotX), axis: (x: 1, y: 0, z: 0))
                    .rotation3DEffect(.degrees(rotY), axis: (x: 0, y: 1, z: 0))
                    .animation(isDragging ? nil : .easeOut(duration: 0.4), value: rotX)
                    .animation(isDragging ? nil : .easeOut(duration: 0.4), value: rotY)
                    .padding(8)
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStart = value.location
                            sendTouchBegan(value.location, in: geo.size)
                        } else {
                            let dx = value.location.x - value.startLocation.x
                            let dy = value.location.y - value.startLocation.y
                            rotY = dx * 0.5
                            rotX = -dy * 0.5
                            sendTouchMoved(value.location, in: geo.size)
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        // Fling: send velocity as fling gesture
                        let vx = value.predictedEndLocation.x - value.location.x
                        let vy = value.predictedEndLocation.y - value.location.y
                        sendFling(vx: vx, vy: vy, in: geo.size)
                        sendTouchEnded(value.location, in: geo.size)
                        WKInterfaceDevice.current().play(.click)
                    }
            )
        }
    }

    // MARK: - Packet helpers

    private func normalize(_ v: CGFloat, size: CGFloat) -> Int16 {
        let t = (v / size) * 2.0 - 1.0
        return Int16(max(-32767, min(32767, t * 32767)))
    }

    private func sendTouchBegan(_ pt: CGPoint, in size: CGSize) {
        let p = TBPPacket.touch(touchId: 0, phase: .began,
                                x: normalize(pt.x, size: size.width),
                                y: normalize(pt.y, size: size.height),
                                pressure: 0)
        sessionManager.send(p)
    }

    private func sendTouchMoved(_ pt: CGPoint, in size: CGSize) {
        let p = TBPPacket.touch(touchId: 0, phase: .moved,
                                x: normalize(pt.x, size: size.width),
                                y: normalize(pt.y, size: size.height),
                                pressure: 0)
        sessionManager.send(p)
    }

    private func sendTouchEnded(_ pt: CGPoint, in size: CGSize) {
        let p = TBPPacket.touch(touchId: 0, phase: .ended,
                                x: normalize(pt.x, size: size.width),
                                y: normalize(pt.y, size: size.height),
                                pressure: 0)
        sessionManager.send(p)
    }

    private func sendFling(vx: CGFloat, vy: CGFloat, in size: CGSize) {
        let normVx = Int16(max(-32767, min(32767, vx / size.width * 32767 * 2)))
        let normVy = Int16(max(-32767, min(32767, vy / size.height * 32767 * 2)))
        let p = TBPPacket.gesture(type: .fling, fingers: 1, param1: normVx, param2: normVy)
        sessionManager.send(p)
    }
}

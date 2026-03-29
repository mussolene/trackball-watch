import SwiftUI
import WatchKit
import Combine

/// Virtual trackball for trackball mode.
/// Sphere sits bottom-trailing for thumb reach; coast damping matches desktop (`trackballFriction` from CONFIG).
struct TrackballView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @StateObject private var engine = TrackballInteractionEngine()

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height) * 0.56
            ZStack(alignment: .bottomTrailing) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                ballView(d: d)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .onReceive(tick) { now in
                let feedback = sessionManager.coastingState
                _ = engine.tickPhysics(
                    now: now,
                    ballDiameter: d,
                    friction: sessionManager.trackballFriction,
                    coastingFeedback: TrackballCoastingFeedback(
                        active: feedback.active,
                        vx: feedback.vx,
                        vy: feedback.vy
                    )
                )
            }
        }
    }

    // MARK: - Ball view

    @ViewBuilder
    private func ballView(d: CGFloat) -> some View {
        ZStack {
            orbitalHalo(d: d)
            SceneKitSphereView(diameter: d, orientation: engine.orientation, isDragging: engine.isDragging)
                .frame(width: d, height: d)
                .shadow(
                    color: .black.opacity(engine.isDragging ? 0.76 : 0.62),
                    radius: engine.isDragging ? 13 : 10,
                    x: 2,
                    y: engine.isDragging ? 12 : 10
                )
        }
        .frame(width: d * 1.34, height: d * 1.34)
        .padding(8)
        .contentShape(Circle())
        .accessibilityLabel("Trackball")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in onDragChanged(v, diameter: d) }
                .onEnded   { v in onDragEnded(v, diameter: d) }
        )
    }

    /// Fixed decorative bezel (does not rotate — only the sphere above does).
    @ViewBuilder
    private func orbitalHalo(d: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(
                    Color(red: 0.38, green: 0.90, blue: 0.97).opacity(engine.isDragging ? 0.55 : 0.38),
                    style: StrokeStyle(lineWidth: max(3, d * 0.05), lineCap: .round)
                )
                .frame(width: d * 1.14, height: d * 1.14)

            Circle()
                .stroke(Color(red: 0.49, green: 0.38, blue: 1.0).opacity(engine.isDragging ? 0.35 : 0.22), lineWidth: max(1, d * 0.016))
                .frame(width: d * 1.24, height: d * 1.24)

            Circle()
                .fill(Color(red: 0.49, green: 0.38, blue: 1.0).opacity(engine.isDragging ? 0.95 : 0.82))
                .frame(width: d * 0.08, height: d * 0.08)
                .offset(x: -d * 0.42, y: d * 0.34)
                .shadow(color: Color(red: 0.49, green: 0.38, blue: 1.0).opacity(0.55), radius: d * 0.08)
        }
    }

    private func onDragChanged(_ value: DragGesture.Value, diameter: CGFloat) {
        send(engine.handleDragChanged(location: value.location, diameter: diameter))
    }

    private func onDragEnded(_ value: DragGesture.Value, diameter: CGFloat) {
        send(engine.handleDragEnded(location: value.location, diameter: diameter))
    }

    private func send(_ events: [TrackballEngineEvent]) {
        for event in events {
            switch event {
            case let .touch(phase, x, y, pressure):
                sessionManager.send(
                    TBPPacket.touch(
                        touchId: 0,
                        phase: touchPhase(phase),
                        x: x,
                        y: y,
                        pressure: pressure
                    )
                )
                if phase == .began {
                    WKInterfaceDevice.current().play(.start)
                }
            case .tap:
                sessionManager.send(TBPPacket.gesture(type: .tap, fingers: 1, param1: 0, param2: 0))
                WKInterfaceDevice.current().play(.click)
            case .doubleTap:
                sessionManager.send(TBPPacket.gesture(type: .doubleTap, fingers: 1, param1: 0, param2: 0))
                WKInterfaceDevice.current().play(.success)
            case .longPress:
                sessionManager.send(TBPPacket.gesture(type: .longPress, fingers: 1, param1: 0, param2: 0))
                WKInterfaceDevice.current().play(.failure)
            case let .fling(vx, vy):
                sessionManager.send(TBPPacket.gesture(type: .fling, fingers: 1, param1: vx, param2: vy))
                WKInterfaceDevice.current().play(.directionUp)
            }
        }
    }

    private func touchPhase(_ phase: TrackballEngineTouchPhase) -> TouchPhase {
        switch phase {
        case .began:
            return .began
        case .moved:
            return .moved
        case .ended:
            return .ended
        case .cancelled:
            return .cancelled
        }
    }
}

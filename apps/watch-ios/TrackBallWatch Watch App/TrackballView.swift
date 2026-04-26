import SwiftUI
import WatchKit
import Combine

/// Virtual trackball for trackball mode.
/// Watch surface mirrors the iPhone debug trackball surface, without the phone-only scroll wheel.
struct TrackballView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore
    @StateObject private var engine = TrackballInteractionEngine()
    @State private var isStreamingCoastTouch = false
    @State private var currentTrackballDiameter: CGFloat = 120

    private let localTrackballFriction = 0.850

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            WatchTrackballSurface(
                engine: engine,
                hostLabel: currentHostLabel,
                canSwitchHosts: hostStore.hosts.count > 1,
                onChanged: onDragChanged,
                onEnded: onDragEnded,
                onTap: handleTapGesture,
                onDoubleTap: handleDoubleTapGesture,
                onLongPress: handleLongPressGesture,
                onSwitchHost: switchToNextHost,
                onDiameterChanged: { diameter in
                    currentTrackballDiameter = diameter
                }
            )
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear {
                sessionManager.refreshWearSide()
            }
            .onReceive(tick) { now in
                _ = engine.tickPhysics(
                    now: now,
                    ballDiameter: currentTrackballDiameter,
                    friction: localTrackballFriction
                )
                if !engine.isDragging && engine.isCoasting {
                    send([engine.currentTouchEvent(phase: .moved, pressure: 0)])
                    isStreamingCoastTouch = true
                } else if isStreamingCoastTouch {
                    send([engine.currentTouchEvent(phase: .ended, pressure: 0)])
                    isStreamingCoastTouch = false
                }
            }
        }
    }

    private var currentHostLabel: String {
        guard let active = hostStore.activeHost else { return "No Host" }
        let name = active.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? active.host : name
    }

    private func switchToNextHost() {
        guard hostStore.hosts.count > 1 else { return }
        hostStore.cycleNext()
        if let active = hostStore.activeHost {
            sessionManager.connectDirectWiFi(to: active)
        }
        WKInterfaceDevice.current().play(.click)
    }

    private func onDragChanged(_ value: DragGesture.Value, diameter: CGFloat) {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let events = engine.handleDragChanged(
            location: value.location,
            sphereCenter: center,
            sphereDiameter: diameter
        )
        send(events)
    }

    private func onDragEnded(_ value: DragGesture.Value, diameter: CGFloat) {
        let events = engine.handleDragEnded(location: value.location, sphereDiameter: diameter)
        send(events)
    }

    private func handleTapGesture() {
        sessionManager.send(TBPPacket.gesture(type: .tap, fingers: 1, param1: 0, param2: 0))
        WKInterfaceDevice.current().play(.click)
    }

    private func handleDoubleTapGesture() {
        sessionManager.send(TBPPacket.gesture(type: .doubleTap, fingers: 1, param1: 0, param2: 0))
        WKInterfaceDevice.current().play(.success)
    }

    private func handleLongPressGesture() {
        sessionManager.send(TBPPacket.gesture(type: .longPress, fingers: 1, param1: 0, param2: 0))
        WKInterfaceDevice.current().play(.failure)
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
                    isStreamingCoastTouch = false
                    WKInterfaceDevice.current().play(.start)
                }
            case .tap, .doubleTap, .longPress:
                break
            case .fling:
                // Fling gesture packets are no longer used for cursor motion.
                break
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

private struct WatchTrackballSurface: View {
    @ObservedObject var engine: TrackballInteractionEngine

    let hostLabel: String
    let canSwitchHosts: Bool
    let onChanged: (DragGesture.Value, CGFloat) -> Void
    let onEnded: (DragGesture.Value, CGFloat) -> Void
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void
    let onSwitchHost: () -> Void
    let onDiameterChanged: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let haloScale: CGFloat = 1.22
            let padInset: CGFloat = 12
            let diameter = Self.trackballDiameter(
                width: geo.size.width,
                height: geo.size.height,
                haloScale: haloScale,
                padInset: padInset
            )
            let outerDiameter = diameter * haloScale

            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.04))

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        .frame(width: diameter * 1.22, height: diameter * 1.22)

                    Circle()
                        .stroke(
                            Color.white.opacity(0.18),
                            style: StrokeStyle(
                                lineWidth: max(4, diameter * 0.05),
                                lineCap: .round
                            )
                        )
                        .frame(width: diameter * 1.08, height: diameter * 1.08)

                    SceneKitSphereView(
                        diameter: diameter,
                        orientation: engine.orientation,
                        isDragging: engine.isDragging
                    )
                    .frame(width: diameter, height: diameter)
                    .shadow(
                        color: .black.opacity(engine.isDragging ? 0.76 : 0.62),
                        radius: engine.isDragging ? 13 : 10,
                        x: 2,
                        y: engine.isDragging ? 12 : 10
                    )
                }
                .frame(width: outerDiameter, height: outerDiameter)
                .overlay {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: diameter, height: diameter)
                        .contentShape(Circle())
                        .simultaneousGesture(
                            ExclusiveGesture(
                                TapGesture(count: 2),
                                TapGesture(count: 1)
                            )
                            .onEnded { result in
                                switch result {
                                case .first:
                                    onDoubleTap()
                                case .second:
                                    onTap()
                                }
                            }
                        )
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.48)
                                .onEnded { _ in
                                    onLongPress()
                                }
                        )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            if !engine.isDragging,
                               !isInsideTrackball(value.location, diameter: diameter, outerDiameter: outerDiameter) {
                                return
                            }
                            onChanged(value, diameter)
                        }
                        .onEnded { value in
                            guard engine.isDragging else { return }
                            onEnded(value, diameter)
                        }
                )
                .accessibilityLabel("Trackball")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button(action: onSwitchHost) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(canSwitchHosts ? 0.18 : 0.09))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSwitchHosts)
                .opacity(canSwitchHosts ? 1.0 : 0.5)
                .padding(8)
                .accessibilityLabel("Switch Desktop")
                .accessibilityHint(hostLabel)
            }
            .onAppear {
                onDiameterChanged(diameter)
            }
            .onChange(of: diameter) { _, newDiameter in
                onDiameterChanged(newDiameter)
            }
        }
    }

    private func isInsideTrackball(_ location: CGPoint, diameter: CGFloat, outerDiameter: CGFloat) -> Bool {
        let radius = diameter * 0.5
        let center = CGPoint(x: outerDiameter * 0.5, y: outerDiameter * 0.5)
        return hypot(location.x - center.x, location.y - center.y) <= radius
    }

    private static func trackballDiameter(
        width: CGFloat,
        height: CGFloat,
        haloScale: CGFloat,
        padInset: CGFloat
    ) -> CGFloat {
        let maxSide = max(1, min(width - padInset, height - padInset))
        return max(104, min(maxSide / haloScale, 170))
    }
}

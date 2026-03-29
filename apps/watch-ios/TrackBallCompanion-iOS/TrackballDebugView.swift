import SwiftUI
import UIKit
import simd

struct TrackballDebugView: View {
    @StateObject private var relay = WatchRelayService.shared
    @StateObject private var pairing = PairingService.shared
    @StateObject private var engine = TrackballInteractionEngine()
    @State private var packetBuilder = DebugTBPPacket()
    @State private var sendToDesktop = false
    @State private var rotateSurface = false
    @State private var showAdvancedTuning = false
    @State private var localTrackballFriction = 0.96
    @State private var deferTouchEndUntilCoastStops = false
    @State private var lastGesture = "None"

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private let tapFeedback = UIImpactFeedbackGenerator(style: .soft)
    private let doubleTapFeedback = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                TrackballRemoteSurface(
                    engine: engine,
                    rotateSurface: rotateSurface,
                    onChanged: onDragChanged,
                    onEnded: onDragEnded
                )
                controlsPanel
                tuningPanel
                statsPanel
            }
            .padding(20)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.08, blue: 0.12),
                    Color(red: 0.03, green: 0.04, blue: 0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Trackball Remote")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            impactFeedback.prepare()
            tapFeedback.prepare()
            doubleTapFeedback.prepare()
            ensureDesktopRelayReady()
        }
        .onChange(of: sendToDesktop) { _, enabled in
            if enabled {
                ensureDesktopRelayReady()
            }
        }
        .onReceive(tick) { now in
            let delta = engine.tickPhysics(
                now: now,
                ballDiameter: 300,
                friction: localTrackballFriction
            )
            streamDesktopCoastingIfNeeded(delta: delta)
        }
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Send To Desktop Host", isOn: $sendToDesktop)
                .tint(.white)
                .foregroundStyle(.white)

            Toggle("Rotate Surface 180°", isOn: $rotateSurface)
                .tint(.white)
                .foregroundStyle(.white)

            Text(desktopRelayStatus)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var tuningPanel: some View {
        DisclosureGroup(isExpanded: $showAdvancedTuning) {
            VStack(alignment: .leading, spacing: 14) {
                sliderRow("Local Friction", value: $localTrackballFriction, range: 0.85...0.995)

                Button("Reset Trackball State") {
                    engine.resetInteractionState()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
            }
            .padding(.top, 12)
        } label: {
            Text("Advanced Tuning")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.06))
        )
        .tint(.white)
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Telemetry")
                .font(.headline)
                .foregroundStyle(.white)

            statRow("Dragging", value: engine.isDragging ? "Yes" : "No")
            statRow(
                "Virtual Contact",
                value: "\(format(engine.virtualContactPoint.x)), \(format(engine.virtualContactPoint.y))"
            )
            statRow(
                "Angular Velocity",
                value: "\(format(engine.angularVelocity.x)), \(format(engine.angularVelocity.y))"
            )
            statRow("Desktop Link", value: desktopLinkText)
            statRow("Packets Relayed", value: "\(relay.packetsRelayed)")
            statRow("Last Gesture", value: lastGesture)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                Text(format(value.wrappedValue))
                    .foregroundStyle(.white.opacity(0.68))
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(.white)
        }
    }

    private func statRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private var desktopLinkText: String {
        switch relay.desktopLinkState {
        case .idle:
            return "Idle"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case let .waiting(message):
            return "Waiting: \(message)"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }

    private var desktopRelayStatus: String {
        if let active = pairing.activeConnection {
            return "Desktop: \(active.host):\(active.port) • \(desktopLinkText)"
        }
        return "No active desktop selected in the companion app."
    }

    private func ensureDesktopRelayReady() {
        if !relay.isRunning {
            relay.start()
        }

        if let active = pairing.activeConnection {
            relay.connectUDP(to: active)
        }
    }

    private func onDragChanged(_ value: DragGesture.Value, diameter: CGFloat) {
        let events = engine.handleDragChanged(
            location: value.location,
            diameter: diameter
        )
        send(events)
    }

    private func onDragEnded(_ value: DragGesture.Value, diameter: CGFloat) {
        let events = engine.handleDragEnded(
            location: value.location,
            diameter: diameter
        )
        sendRelease(events)
    }

    private func send(_ events: [TrackballEngineEvent]) {
        for event in events {
            switch event {
            case let .touch(phase, x, y, pressure):
                if phase == .began {
                    impactFeedback.impactOccurred(intensity: 0.45)
                }
                sendTouch(phase: phase, x: x, y: y, pressure: pressure)
            case .tap:
                tapFeedback.impactOccurred(intensity: 0.7)
                lastGesture = "Tap"
                sendGesture(.tap)
            case .doubleTap:
                doubleTapFeedback.impactOccurred(intensity: 0.9)
                lastGesture = "Double Tap"
                sendGesture(.doubleTap)
            case .longPress:
                impactFeedback.impactOccurred(intensity: 0.85)
                lastGesture = "Long Press"
                sendGesture(.longPress)
            case let .fling(vx, vy):
                impactFeedback.impactOccurred(intensity: 0.7)
                lastGesture = "Fling"
                sendFling(vx: vx, vy: vy)
            }
        }
    }

    private func sendRelease(_ events: [TrackballEngineEvent]) {
        let hasFling = events.contains { event in
            if case .fling = event { return true }
            return false
        }

        for event in events {
            switch event {
            case let .touch(phase, x, y, pressure):
                if phase == .ended && hasFling {
                    deferTouchEndUntilCoastStops = sendToDesktop && engine.isCoasting
                    if !deferTouchEndUntilCoastStops {
                        sendTouch(phase: phase, x: x, y: y, pressure: pressure)
                    }
                } else {
                    sendTouch(phase: phase, x: x, y: y, pressure: pressure)
                }
            case .tap:
                tapFeedback.impactOccurred(intensity: 0.7)
                lastGesture = "Tap"
                sendGesture(.tap)
                deferTouchEndUntilCoastStops = false
            case .doubleTap:
                doubleTapFeedback.impactOccurred(intensity: 0.9)
                lastGesture = "Double Tap"
                sendGesture(.doubleTap)
                deferTouchEndUntilCoastStops = false
            case .longPress:
                impactFeedback.impactOccurred(intensity: 0.85)
                lastGesture = "Long Press"
                sendGesture(.longPress)
                deferTouchEndUntilCoastStops = false
            case let .fling(vx, vy):
                impactFeedback.impactOccurred(intensity: 0.7)
                lastGesture = "Fling"
                if !deferTouchEndUntilCoastStops {
                    sendFling(vx: vx, vy: vy)
                }
            }
        }
    }

    private func streamDesktopCoastingIfNeeded(delta: CGPoint) {
        guard sendToDesktop, deferTouchEndUntilCoastStops else { return }

        if delta != .zero {
            if case let .touch(phase, x, y, pressure) = engine.currentTouchEvent(phase: .moved) {
                sendTouch(phase: phase, x: x, y: y, pressure: pressure)
            }
        }

        if !engine.isCoasting {
            deferTouchEndUntilCoastStops = false
            if case let .touch(phase, x, y, pressure) = engine.currentTouchEvent(phase: .ended) {
                sendTouch(phase: phase, x: x, y: y, pressure: pressure)
            }
        }
    }

    private func sendTouch(phase: TrackballEngineTouchPhase, x: Int16, y: Int16, pressure: UInt8) {
        guard sendToDesktop else { return }
        ensureDesktopRelayReady()
        relay.relay(packetBuilder.touch(phase: debugTouchPhase(phase), x: x, y: y, pressure: pressure))
    }

    private func sendFling(vx: Int16, vy: Int16) {
        guard sendToDesktop else { return }
        ensureDesktopRelayReady()
        relay.relay(packetBuilder.fling(vx: vx, vy: vy))
    }

    private func sendGesture(_ gesture: DebugGestureType) {
        guard sendToDesktop else { return }
        ensureDesktopRelayReady()
        relay.relay(packetBuilder.gesture(gesture))
    }

    private func debugTouchPhase(_ phase: TrackballEngineTouchPhase) -> DebugTouchPhase {
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

private struct TrackballRemoteSurface: View {
    @ObservedObject var engine: TrackballInteractionEngine

    let rotateSurface: Bool
    let onChanged: (DragGesture.Value, CGFloat) -> Void
    let onEnded: (DragGesture.Value, CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trackball")
                .font(.headline)
                .foregroundStyle(.white)

            GeometryReader { geo in
                let diameter = min(geo.size.width, 300)
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.white.opacity(0.04))

                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            .frame(width: diameter * 1.22, height: diameter * 1.22)

                        Circle()
                            .stroke(Color.white.opacity(0.18),
                                    style: StrokeStyle(
                                        lineWidth: max(5, diameter * 0.05),
                                        lineCap: .round
                                    ))
                            .frame(width: diameter * 1.08, height: diameter * 1.08)

                        TrackballGlobeView(
                            orientation: engine.orientation,
                            diameter: diameter
                        )
                    }
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(rotateSurface ? 180 : 0))
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in onChanged(value, diameter) }
                            .onEnded { value in onEnded(value, diameter) }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 380)
        }
    }
}

private struct TrackballGlobeView: View {
    let orientation: simd_quatd
    let diameter: CGFloat

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) * 0.5

            let bodyRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            context.fill(
                Path(ellipseIn: bodyRect),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.14),
                        Color(red: 0.15, green: 0.18, blue: 0.24),
                        Color(red: 0.05, green: 0.06, blue: 0.09)
                    ]),
                    center: CGPoint(x: rect.width * 0.34, y: rect.height * 0.28),
                    startRadius: 6,
                    endRadius: radius * 1.15
                )
            )

            context.stroke(
                Path(ellipseIn: bodyRect),
                with: .color(Color.white.opacity(0.08)),
                lineWidth: 1
            )

            for latitude in stride(from: -80.0, through: 80.0, by: 10.0) {
                strokeProjectedCircle(
                    context: &context,
                    center: center,
                    radius: radius,
                    samples: latitudeCircle(latitudeDegrees: latitude),
                    color: Color.white.opacity(0.17),
                    lineWidth: max(0.8, diameter * 0.004)
                )
            }

            for longitude in stride(from: 0.0, through: 170.0, by: 10.0) {
                strokeProjectedCircle(
                    context: &context,
                    center: center,
                    radius: radius,
                    samples: longitudeCircle(longitudeDegrees: longitude),
                    color: Color.white.opacity(0.22),
                    lineWidth: max(0.8, diameter * 0.0045)
                )
            }

        }
        .frame(width: diameter, height: diameter)
    }

    private func latitudeCircle(latitudeDegrees: Double) -> [SIMD3<Double>] {
        let latitude = latitudeDegrees * .pi / 180.0
        let y = sin(latitude)
        let ringRadius = cos(latitude)
        return stride(from: 0.0, through: 360.0, by: 6.0).map { angleDegrees in
            let angle = angleDegrees * .pi / 180.0
            return SIMD3<Double>(
                ringRadius * cos(angle),
                y,
                ringRadius * sin(angle)
            )
        }
    }

    private func longitudeCircle(longitudeDegrees: Double) -> [SIMD3<Double>] {
        let longitude = longitudeDegrees * .pi / 180.0
        return stride(from: -90.0, through: 90.0, by: 4.0).map { latitudeDegrees in
            let latitude = latitudeDegrees * .pi / 180.0
            let x = cos(latitude) * cos(longitude)
            let y = sin(latitude)
            let z = cos(latitude) * sin(longitude)
            return SIMD3<Double>(x, y, z)
        }
    }

    private func strokeProjectedCircle(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        samples: [SIMD3<Double>],
        color: Color,
        lineWidth: CGFloat
    ) {
        guard !samples.isEmpty else { return }

        var frontPath = Path()
        var backPath = Path()
        var frontStarted = false
        var backStarted = false

        for point in samples {
            let rotated = orientation.act(point)
            let projected = CGPoint(
                x: center.x + CGFloat(rotated.x) * radius,
                y: center.y - CGFloat(rotated.y) * radius
            )

            if rotated.z >= 0 {
                if frontStarted {
                    frontPath.addLine(to: projected)
                } else {
                    frontPath.move(to: projected)
                    frontStarted = true
                }
                backStarted = false
            } else {
                if backStarted {
                    backPath.addLine(to: projected)
                } else {
                    backPath.move(to: projected)
                    backStarted = true
                }
                frontStarted = false
            }
        }

        context.stroke(backPath, with: .color(color.opacity(0.07)), lineWidth: lineWidth)
        context.stroke(frontPath, with: .color(color), lineWidth: lineWidth)
    }
}

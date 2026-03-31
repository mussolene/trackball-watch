import SwiftUI
import UIKit
import simd

/// iPhone screen for testing the shared trackball engine and relaying to the desktop host.
struct TrackballRemoteView: View {
    @StateObject private var relay = WatchRelayService.shared
    @StateObject private var pairing = PairingService.shared
    @StateObject private var engine = TrackballInteractionEngine()
    @State private var packetBuilder = DebugTBPPacket()
    @State private var sendToDesktop = false
    @State private var showAdvancedTuning = false
    @State private var localTrackballFriction = 0.96
    @State private var deferTouchEndUntilCoastStops = false
    @State private var lastGesture = "None"
    @State private var visibleFingerLocation: CGPoint?
    @State private var currentTrackballDiameter: CGFloat = 300

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private let tapFeedback = UIImpactFeedbackGenerator(style: .soft)
    private let doubleTapFeedback = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            Group {
                if isLandscape {
                    HStack(alignment: .top, spacing: 20) {
                        trackballPanel(containerSize: geo.size, isLandscape: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        ScrollView {
                            settingsPanel
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            trackballPanel(containerSize: geo.size, isLandscape: false)
                            settingsPanel
                        }
                        .padding(20)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
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
                ballDiameter: currentTrackballDiameter,
                friction: localTrackballFriction
            )
            streamRollingTouchToDesktopIfNeeded(delta: delta)
            streamDesktopCoastingIfNeeded(delta: delta)
        }
    }

    private func trackballPanel(containerSize: CGSize, isLandscape: Bool) -> some View {
        let portraitHeight = min(max(260, containerSize.width - 40), containerSize.height * 0.52)
        return TrackballRemoteSurface(
            engine: engine,
            fingerLocation: visibleFingerLocation,
            onChanged: onDragChanged,
            onEnded: onDragEnded,
            onTap: handleTapGesture,
            onDoubleTap: handleDoubleTapGesture,
            onLongPress: handleLongPressGesture,
            onDiameterChanged: { diameter in
                currentTrackballDiameter = diameter
            }
        )
        .frame(
            maxWidth: .infinity,
            minHeight: isLandscape ? 260 : portraitHeight,
            maxHeight: isLandscape ? .infinity : portraitHeight,
            alignment: .top
        )
        .padding(20)
    }

    private var settingsPanel: some View {
        VStack(spacing: 20) {
            controlsPanel
            tuningPanel
            statsPanel
        }
        .padding(20)
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Send To Desktop Host", isOn: $sendToDesktop)
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
        visibleFingerLocation = value.location
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let events = engine.handleDragChanged(
            location: value.location,
            sphereCenter: center,
            sphereDiameter: diameter
        )
        send(events)
    }

    private func onDragEnded(_ value: DragGesture.Value, diameter: CGFloat) {
        visibleFingerLocation = nil
        let events = engine.handleDragEnded(
            location: value.location,
            sphereDiameter: diameter
        )
        sendRelease(events)
    }

    private func handleTapGesture() {
        tapFeedback.impactOccurred(intensity: 0.7)
        lastGesture = "Tap"
        deferTouchEndUntilCoastStops = false
        sendGesture(.tap)
    }

    private func handleDoubleTapGesture() {
        doubleTapFeedback.impactOccurred(intensity: 0.9)
        lastGesture = "Double Tap"
        deferTouchEndUntilCoastStops = false
        sendGesture(.doubleTap)
    }

    private func handleLongPressGesture() {
        impactFeedback.impactOccurred(intensity: 0.85)
        lastGesture = "Long Press"
        deferTouchEndUntilCoastStops = false
        sendGesture(.longPress)
    }

    private func send(_ events: [TrackballEngineEvent]) {
        for event in events {
            switch event {
            case let .touch(phase, x, y, pressure):
                if phase == .began {
                    impactFeedback.impactOccurred(intensity: 0.45)
                }
                sendTouch(phase: phase, x: x, y: y, pressure: pressure)
            case .tap, .doubleTap, .longPress:
                break
            case let .fling(vx, vy):
                impactFeedback.impactOccurred(intensity: 0.7)
                lastGesture = "Fling"
                sendFling(vx: vx, vy: vy)
            }
        }
    }

    private func sendRelease(_ events: [TrackballEngineEvent]) {
        let shouldDeferTouchEnd = sendToDesktop && engine.isCoasting

        for event in events {
            switch event {
            case let .touch(phase, x, y, pressure):
                if phase == .ended && shouldDeferTouchEnd {
                    deferTouchEndUntilCoastStops = true
                    if !deferTouchEndUntilCoastStops {
                        sendTouch(phase: phase, x: x, y: y, pressure: pressure)
                    }
                } else {
                    sendTouch(phase: phase, x: x, y: y, pressure: pressure)
                }
            case .tap, .doubleTap, .longPress:
                break
            case let .fling(vx, vy):
                impactFeedback.impactOccurred(intensity: 0.7)
                lastGesture = "Fling"
                if !shouldDeferTouchEnd {
                    sendFling(vx: vx, vy: vy)
                }
            }
        }
    }

    private func streamRollingTouchToDesktopIfNeeded(delta: CGPoint) {
        guard sendToDesktop else { return }
        guard engine.isDragging, hypot(delta.x, delta.y) > 1e-5 else { return }
        if case let .touch(phase, x, y, pressure) = engine.currentTouchEvent(phase: .moved) {
            ensureDesktopRelayReady()
            relay.relay(packetBuilder.touch(phase: companionTouchPhase(phase), x: x, y: y, pressure: pressure))
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
        relay.relay(packetBuilder.touch(phase: companionTouchPhase(phase), x: x, y: y, pressure: pressure))
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

    private func companionTouchPhase(_ phase: TrackballEngineTouchPhase) -> DebugTouchPhase {
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

    let fingerLocation: CGPoint?
    let onChanged: (DragGesture.Value, CGFloat) -> Void
    let onEnded: (DragGesture.Value, CGFloat) -> Void
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void
    let onDiameterChanged: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let diameter = max(180, min(geo.size.width - 24, geo.size.height - 24, 420))
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
                        diameter: diameter,
                        fingerLocation: fingerLocation
                    )
                }
                .frame(width: diameter, height: diameter)
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
                               !isInsideTrackball(value.location, diameter: diameter) {
                                return
                            }
                            onChanged(value, diameter)
                        }
                        .onEnded { value in
                            guard engine.isDragging else { return }
                            onEnded(value, diameter)
                        }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                onDiameterChanged(diameter)
            }
            .onChange(of: diameter) { _, newDiameter in
                onDiameterChanged(newDiameter)
            }
        }
    }

    private func isInsideTrackball(_ location: CGPoint, diameter: CGFloat) -> Bool {
        let radius = diameter * 0.5
        let center = CGPoint(x: radius, y: radius)
        return hypot(location.x - center.x, location.y - center.y) <= radius
    }
}

// MARK: - Globe grid (orthographic projection)

private struct TrackballGlobeView: View {
    let orientation: simd_quatd
    let diameter: CGFloat
    let fingerLocation: CGPoint?

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

            // Parallels: full small circles (latitude constant), closed.
            for latitude in stride(from: -80.0, through: 80.0, by: 10.0) {
                strokeProjectedCircle(
                    context: &context,
                    center: center,
                    radius: radius,
                    orientation: orientation,
                    samples: parallelSamples(latitudeDegrees: latitude),
                    color: Color.white.opacity(0.2),
                    lineWidth: max(0.7, diameter * 0.0035),
                    closed: true
                )
            }

            // Meridians: full great circles (two semicircles at φ and φ+180°), closed.
            for longitude in stride(from: 0.0, through: 170.0, by: 10.0) {
                strokeProjectedCircle(
                    context: &context,
                    center: center,
                    radius: radius,
                    orientation: orientation,
                    samples: meridianSamples(longitudeDegrees: longitude),
                    color: Color.white.opacity(0.26),
                    lineWidth: max(0.75, diameter * 0.004),
                    closed: true
                )
            }

            if let fingerLocation, hypot(fingerLocation.x - center.x, fingerLocation.y - center.y) <= radius {
                let markerRect = CGRect(
                    x: fingerLocation.x - 11,
                    y: fingerLocation.y - 11,
                    width: 22,
                    height: 22
                )
                context.stroke(
                    Path(ellipseIn: markerRect),
                    with: .color(.white.opacity(0.92)),
                    lineWidth: 2
                )
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: fingerLocation.x - 3,
                        y: fingerLocation.y - 3,
                        width: 6,
                        height: 6
                    )),
                    with: .color(.white.opacity(0.92))
                )
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// Unit-sphere points on a parallel (latitude fixed, longitude sweeps 360°).
    private func parallelSamples(latitudeDegrees: Double) -> [SIMD3<Double>] {
        let latitude = latitudeDegrees * .pi / 180.0
        let y = sin(latitude)
        let ringRadius = cos(latitude)
        return stride(from: 0.0, through: 355.0, by: 5.0).map { angleDegrees in
            let angle = angleDegrees * .pi / 180.0
            return SIMD3<Double>(
                ringRadius * cos(angle),
                y,
                ringRadius * sin(angle)
            )
        }
    }

    /// Full meridian = two pole-to-pole semicircles (φ and φ+π); one half alone only draws 180° of the great circle.
    private func meridianSamples(longitudeDegrees: Double) -> [SIMD3<Double>] {
        let lon = longitudeDegrees * .pi / 180.0
        let lonOpp = lon + .pi
        let step: Double = 5.0
        var pts: [SIMD3<Double>] = []
        var lat = -90.0
        while lat <= 90.0 + 1e-6 {
            pts.append(sphericalUnit(latitudeDegrees: lat, longitudeRadians: lon))
            lat += step
        }
        lat = 90.0 - step
        while lat >= -90.0 {
            pts.append(sphericalUnit(latitudeDegrees: lat, longitudeRadians: lonOpp))
            lat -= step
        }
        return pts
    }

    private func sphericalUnit(latitudeDegrees: Double, longitudeRadians: Double) -> SIMD3<Double> {
        let lat = latitudeDegrees * .pi / 180.0
        return SIMD3<Double>(
            cos(lat) * cos(longitudeRadians),
            sin(lat),
            cos(lat) * sin(longitudeRadians)
        )
    }

    /// Orthographic projection of a circle on the sphere: stroke edge segments; `closed` connects last→first.
    private func strokeProjectedCircle(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        orientation: simd_quatd,
        samples: [SIMD3<Double>],
        color: Color,
        lineWidth: CGFloat,
        closed: Bool
    ) {
        let n = samples.count
        guard n >= 2 else { return }

        let edgeCount = closed ? n : n - 1
        guard edgeCount >= 1 else { return }

        var frontPath = Path()
        var backPath = Path()
        var drawingFront: Bool?
        var drawingBack: Bool?

        for i in 0 ..< edgeCount {
            let i0 = i % n
            let i1 = (i + 1) % n
            let r0 = orientation.act(samples[i0])
            let r1 = orientation.act(samples[i1])
            let p0 = CGPoint(
                x: center.x + CGFloat(r0.x) * radius,
                y: center.y - CGFloat(r0.y) * radius
            )
            let p1 = CGPoint(
                x: center.x + CGFloat(r1.x) * radius,
                y: center.y - CGFloat(r1.y) * radius
            )
            let onFront = (r0.z + r1.z) * 0.5 >= 0

            if onFront {
                if drawingFront != true {
                    frontPath.move(to: p0)
                    drawingFront = true
                    drawingBack = false
                }
                frontPath.addLine(to: p1)
            } else {
                if drawingBack != true {
                    backPath.move(to: p0)
                    drawingBack = true
                    drawingFront = false
                }
                backPath.addLine(to: p1)
            }
        }

        context.stroke(backPath, with: .color(color.opacity(0.55)), lineWidth: lineWidth)
        context.stroke(frontPath, with: .color(color), lineWidth: lineWidth)
    }
}

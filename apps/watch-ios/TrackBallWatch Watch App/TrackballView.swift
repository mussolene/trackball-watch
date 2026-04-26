import SwiftUI
import WatchKit
import simd

/// Watch trackball surface copied from the iPhone debug remote mechanics, adapted for watchOS.
struct TrackballView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore

    @StateObject private var engine = TrackballInteractionEngine()
    @State private var isStreamingCoastTouch = false
    @State private var currentTrackballDiameter: CGFloat = 120
    @State private var visibleFingerLocation: CGPoint?
    @State private var showSettings = false
    @State private var localTrackballFriction = 0.850
    @State private var virtualTrackballScale = 1.0

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var currentHostLabel: String {
        guard let active = hostStore.activeHost else { return "No Host" }
        let name = active.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? active.host : name
    }

    private var currentVirtualTrackballDiameter: CGFloat {
        let scaledDiameter = currentTrackballDiameter * CGFloat(virtualTrackballScale)
        return min(max(120, scaledDiameter), 900)
    }

    var body: some View {
        GeometryReader { geo in
            WatchTrackballRemoteSurface(
                engine: engine,
                fingerLocation: visibleFingerLocation,
                hostLabel: currentHostLabel,
                canSwitchHosts: hostStore.hosts.count > 1,
                onChanged: onDragChanged,
                onEnded: onDragEnded,
                onTap: handleTapGesture,
                onDoubleTap: handleDoubleTapGesture,
                onLongPress: handleLongPressGesture,
                onSwitchHost: switchToNextHost,
                onSettings: showSettingsPanel,
                onDiameterChanged: { diameter in
                    currentTrackballDiameter = diameter
                }
            )
            .frame(width: geo.size.width, height: geo.size.height)
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
        .onAppear {
            sessionManager.refreshWearSide()
        }
        .onReceive(tick, perform: tickPhysics)
        .sheet(isPresented: $showSettings) {
            WatchTrackballSettingsView(
                hostLabel: currentHostLabel,
                connectionText: connectionText,
                virtualTrackballScale: $virtualTrackballScale,
                localTrackballFriction: $localTrackballFriction,
                currentVirtualDiameter: currentVirtualTrackballDiameter,
                onReset: resetTrackballState
            )
        }
    }
}

// MARK: - Actions

private extension TrackballView {
    var connectionText: String {
        switch sessionManager.connectionState {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            switch sessionManager.transportMode {
            case .directWiFi:
                return "Direct Wi-Fi"
            case .wcRelay:
                return "iPhone Relay"
            case .none:
                return "Connected"
            }
        }
    }

    func showSettingsPanel() {
        showSettings = true
        WKInterfaceDevice.current().play(.click)
    }

    func resetTrackballState() {
        visibleFingerLocation = nil
        isStreamingCoastTouch = false
        engine.resetInteractionState()
        WKInterfaceDevice.current().play(.click)
    }

    func tickPhysics(_ now: Date) {
        _ = engine.tickPhysics(
            now: now,
            ballDiameter: currentVirtualTrackballDiameter,
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

    func switchToNextHost() {
        guard hostStore.hosts.count > 1 else { return }
        hostStore.cycleNext()
        if let active = hostStore.activeHost {
            sessionManager.connectDirectWiFi(to: active)
        }
        WKInterfaceDevice.current().play(.click)
    }

    func onDragChanged(_ value: DragGesture.Value, diameter: CGFloat) {
        visibleFingerLocation = value.location
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let events = engine.handleDragChanged(
            location: value.location,
            sphereCenter: center,
            sphereDiameter: currentVirtualTrackballDiameter
        )
        send(events)
    }

    func onDragEnded(_ value: DragGesture.Value, diameter: CGFloat) {
        visibleFingerLocation = nil
        let events = engine.handleDragEnded(
            location: value.location,
            sphereDiameter: currentVirtualTrackballDiameter
        )
        send(events)
    }

    func handleTapGesture() {
        sessionManager.send(TBPPacket.gesture(type: .tap, fingers: 1, param1: 0, param2: 0))
        WKInterfaceDevice.current().play(.click)
    }

    func handleDoubleTapGesture() {
        sessionManager.send(TBPPacket.gesture(type: .doubleTap, fingers: 1, param1: 0, param2: 0))
        WKInterfaceDevice.current().play(.success)
    }

    func handleLongPressGesture() {
        sessionManager.send(TBPPacket.gesture(type: .longPress, fingers: 1, param1: 0, param2: 0))
        WKInterfaceDevice.current().play(.failure)
    }

    func send(_ events: [TrackballEngineEvent]) {
        for event in events {
            switch event {
            case let .touch(phase, x, y, pressure):
                if phase == .began {
                    isStreamingCoastTouch = false
                    WKInterfaceDevice.current().play(.start)
                }
                sessionManager.send(
                    TBPPacket.touch(
                        touchId: 0,
                        phase: touchPhase(phase),
                        x: x,
                        y: y,
                        pressure: pressure
                    )
                )
            case .tap, .doubleTap, .longPress:
                break
            case .fling:
                break
            }
        }
    }

    func touchPhase(_ phase: TrackballEngineTouchPhase) -> TouchPhase {
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

// MARK: - Surface

private struct WatchTrackballRemoteSurface: View {
    @ObservedObject var engine: TrackballInteractionEngine

    let fingerLocation: CGPoint?
    let hostLabel: String
    let canSwitchHosts: Bool
    let onChanged: (DragGesture.Value, CGFloat) -> Void
    let onEnded: (DragGesture.Value, CGFloat) -> Void
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void
    let onSwitchHost: () -> Void
    let onSettings: () -> Void
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
            let globeInset = (outerDiameter - diameter) / 2
            let fingerInGlobeCanvas = fingerLocation.map { loc in
                CGPoint(x: loc.x - globeInset, y: loc.y - globeInset)
            }

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

                    WatchTrackballGlobeView(
                        orientation: engine.orientation,
                        diameter: diameter,
                        fingerLocation: fingerInGlobeCanvas
                    )
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
                SurfaceIconButton(
                    systemName: "desktopcomputer",
                    isEnabled: canSwitchHosts,
                    action: onSwitchHost
                )
                .disabled(!canSwitchHosts)
                .opacity(canSwitchHosts ? 1.0 : 0.5)
                .padding(8)
                .accessibilityLabel("Switch Desktop")
                .accessibilityHint(hostLabel)
            }
            .overlay(alignment: .bottomTrailing) {
                SurfaceIconButton(
                    systemName: "gearshape",
                    isEnabled: true,
                    action: onSettings
                )
                .padding(8)
                .accessibilityLabel("Trackball Settings")
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

private struct SurfaceIconButton: View {
    let systemName: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isEnabled ? 0.18 : 0.09))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings

private struct WatchTrackballSettingsView: View {
    let hostLabel: String
    let connectionText: String
    @Binding var virtualTrackballScale: Double
    @Binding var localTrackballFriction: Double
    let currentVirtualDiameter: CGFloat
    let onReset: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(hostLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(connectionText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))

                SliderRow(
                    title: "Ball Size",
                    value: $virtualTrackballScale,
                    range: 0.55...10.0
                )

                Text("\(Int(currentVirtualDiameter.rounded())) pt")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.68))
                    .monospacedDigit()

                SliderRow(
                    title: "Friction",
                    value: $localTrackballFriction,
                    range: 0.550...0.995
                )

                Button("Reset") {
                    onReset()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))
            }
            .padding(14)
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.07).ignoresSafeArea())
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.3f", value))
                    .foregroundStyle(.white.opacity(0.68))
                    .monospacedDigit()
            }
            .font(.caption)

            Slider(value: $value, in: range)
                .tint(.white)
        }
    }
}

// MARK: - Globe

private struct WatchTrackballGlobeView: View {
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

            if let fingerLocation,
               hypot(fingerLocation.x - center.x, fingerLocation.y - center.y) <= radius {
                let markerSize = max(14, diameter * 0.085)
                let markerRect = CGRect(
                    x: fingerLocation.x - markerSize * 0.5,
                    y: fingerLocation.y - markerSize * 0.5,
                    width: markerSize,
                    height: markerSize
                )
                context.stroke(
                    Path(ellipseIn: markerRect),
                    with: .color(.white.opacity(0.92)),
                    lineWidth: max(1.4, diameter * 0.012)
                )
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: fingerLocation.x - 2.5,
                        y: fingerLocation.y - 2.5,
                        width: 5,
                        height: 5
                    )),
                    with: .color(.white.opacity(0.92))
                )
            }
        }
        .frame(width: diameter, height: diameter)
    }

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

    private func meridianSamples(longitudeDegrees: Double) -> [SIMD3<Double>] {
        let lon = longitudeDegrees * .pi / 180.0
        let lonOpp = lon + .pi
        let step = 5.0
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

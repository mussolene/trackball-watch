import SwiftUI
import WatchKit
import simd

/// Watch trackball surface intentionally mirrors the iPhone debug remote mechanics.
struct TrackballView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @EnvironmentObject var hostStore: HostStore

    @StateObject private var engine = TrackballInteractionEngine()
    @State private var isStreamingCoastTouch = false
    @State private var currentTrackballDiameter: CGFloat = 120
    @State private var visibleFingerLocation: CGPoint?
    @State private var localTrackballFriction = 0.850
    @State private var virtualTrackballScale = 1.0
    @State private var isScrollDragging = false
    @State private var lastScrollLocationY: CGFloat?
    @State private var lastScrollTimestamp: Date = .now

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
            trackballPanel(containerSize: geo.size)
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
    }

    private func trackballPanel(containerSize: CGSize) -> some View {
        TrackballRemoteSurface(
            engine: engine,
            fingerLocation: visibleFingerLocation,
            hostLabel: currentHostLabel,
            canSwitchHosts: hostStore.hosts.count > 1,
            isScrollDragging: isScrollDragging,
            onChanged: onDragChanged,
            onEnded: onDragEnded,
            onTap: handleTapGesture,
            onDoubleTap: handleDoubleTapGesture,
            onLongPress: handleLongPressGesture,
            onScrollChanged: handleScrollChanged,
            onScrollEnded: handleScrollEnded,
            onSwitchHost: switchToNextHost,
            onDiameterChanged: { diameter in
                currentTrackballDiameter = diameter
            }
        )
        .frame(width: containerSize.width, height: containerSize.height)
        .ignoresSafeArea()
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

    func handleScrollChanged(_ value: DragGesture.Value) {
        let now = Date.now
        if !isScrollDragging {
            isScrollDragging = true
            lastScrollLocationY = value.location.y
            lastScrollTimestamp = now
            WKInterfaceDevice.current().play(.start)
            return
        }

        guard let previousY = lastScrollLocationY else {
            lastScrollLocationY = value.location.y
            lastScrollTimestamp = now
            return
        }

        let deltaPoints = previousY - value.location.y
        let dt = max(1e-3, now.timeIntervalSince(lastScrollTimestamp))
        lastScrollLocationY = value.location.y
        lastScrollTimestamp = now

        let rawDelta = Int((deltaPoints * 4.0).rounded())
        guard rawDelta != 0 else { return }

        let velocity = Int((Double(rawDelta) / dt / 10.0).rounded())
        sessionManager.send(
            TBPPacket.crown(
                delta: Int16(clamping: rawDelta),
                velocity: Int16(clamping: velocity)
            )
        )
        WKInterfaceDevice.current().play(.click)
    }

    func handleScrollEnded() {
        isScrollDragging = false
        lastScrollLocationY = nil
        lastScrollTimestamp = .now
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

private struct TrackballRemoteSurface: View {
    @ObservedObject var engine: TrackballInteractionEngine

    let fingerLocation: CGPoint?
    let hostLabel: String
    let canSwitchHosts: Bool
    let isScrollDragging: Bool
    let onChanged: (DragGesture.Value, CGFloat) -> Void
    let onEnded: (DragGesture.Value, CGFloat) -> Void
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPress: () -> Void
    let onScrollChanged: (DragGesture.Value) -> Void
    let onScrollEnded: () -> Void
    let onSwitchHost: () -> Void
    let onDiameterChanged: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let haloScale: CGFloat = 1.22
            let padInset: CGFloat = 24
            let layout = Self.layoutForPad(
                width: geo.size.width,
                height: geo.size.height,
                haloScale: haloScale,
                padInset: padInset
            )
            let diameter = layout.diameter
            let outerDiameter = layout.outerDiameter
            let scrollWheelGap = layout.scrollWheelGap
            let scrollWheelWidth = layout.scrollWheelWidth
            let scrollWheelHeight = layout.scrollWheelHeight
            // DragGesture is on the inner `outerDiameter` ZStack, so `value.location` is in that
            // square's local space - not the full `geo`. The globe Canvas is centered inside it.
            let globeInset = (outerDiameter - diameter) / 2
            let fingerInGlobeCanvas: CGPoint? = fingerLocation.map { loc in
                CGPoint(x: loc.x - globeInset, y: loc.y - globeInset)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.white.opacity(0.04))

                HStack(alignment: .center, spacing: scrollWheelGap) {
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
                            fingerLocation: fingerInGlobeCanvas
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

                    MouseScrollWheelControl(
                        isActive: isScrollDragging,
                        wheelHeight: scrollWheelHeight,
                        wheelWidth: scrollWheelWidth
                    )
                    .frame(width: scrollWheelWidth, height: scrollWheelHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged(onScrollChanged)
                            .onEnded { _ in
                                onScrollEnded()
                            }
                    )
                    .accessibilityLabel("Scroll")
                    .accessibilityHint("Drag up or down to scroll the desktop")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button(action: onSwitchHost) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
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
                .padding(14)
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

    private static func layoutForPad(
        width: CGFloat,
        height: CGFloat,
        haloScale: CGFloat,
        padInset: CGFloat
    ) -> (
        diameter: CGFloat,
        outerDiameter: CGFloat,
        scrollWheelGap: CGFloat,
        scrollWheelWidth: CGFloat,
        scrollWheelHeight: CGFloat
    ) {
        let maxSide = min(width - padInset, height - padInset)
        var diameter = max(180, min(maxSide / haloScale, 420))
        var outerDiameter = diameter * haloScale
        var scrollWheelGap = max(8, min(14, outerDiameter * 0.035))
        var scrollWheelWidth = max(22, min(30, outerDiameter * 0.082))
        while diameter > 120
            && outerDiameter + scrollWheelGap + scrollWheelWidth > width - padInset {
            diameter -= 4
            outerDiameter = diameter * haloScale
            scrollWheelGap = max(8, min(14, outerDiameter * 0.035))
            scrollWheelWidth = max(22, min(30, outerDiameter * 0.082))
        }
        let scrollWheelHeight = min(
            max(130, outerDiameter * 0.88),
            min(outerDiameter * 0.96, height - 40)
        )
        return (diameter, outerDiameter, scrollWheelGap, scrollWheelWidth, scrollWheelHeight)
    }
}

private struct MouseScrollWheelControl: View {
    let isActive: Bool
    let wheelHeight: CGFloat
    let wheelWidth: CGFloat

    private var ridgeCount: Int {
        let n = Int((wheelHeight / 14).rounded(.down))
        return max(5, min(11, n))
    }

    var body: some View {
        let corner = wheelWidth * 0.42
        ZStack {
            RoundedRectangle(cornerRadius: corner + 3)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.06),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner + 3)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .padding(-3)

            RoundedRectangle(cornerRadius: corner)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.22).opacity(isActive ? 1.0 : 0.92),
                            Color(white: 0.10).opacity(isActive ? 1.0 : 0.88),
                            Color(white: 0.06).opacity(0.95)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isActive ? 0.38 : 0.22),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.45), radius: isActive ? 5 : 3, y: 2)

            VStack(spacing: max(3, wheelHeight * 0.022)) {
                ForEach(0 ..< ridgeCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 0.8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isActive ? 0.42 : 0.26),
                                    Color.white.opacity(0.10)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: max(1.5, wheelWidth * 0.12))
                        .opacity(i % 2 == 0 ? 1.0 : 0.72)
                }
            }
            .padding(.vertical, wheelHeight * 0.07)
            .padding(.horizontal, wheelWidth * 0.14)

            VStack {
                Capsule()
                    .fill(Color.white.opacity(isActive ? 0.20 : 0.12))
                    .frame(height: 2)
                    .padding(.horizontal, wheelWidth * 0.12)
                Spacer()
                Capsule()
                    .fill(Color.white.opacity(isActive ? 0.16 : 0.10))
                    .frame(height: 2)
                    .padding(.horizontal, wheelWidth * 0.12)
            }
            .padding(.vertical, 2)
        }
        .frame(width: wheelWidth, height: wheelHeight)
    }
}

// MARK: - Globe

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

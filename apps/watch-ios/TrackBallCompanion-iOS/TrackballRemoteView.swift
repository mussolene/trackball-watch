import SwiftUI
import UIKit
import simd
import OSLog
import Foundation

/// iPhone screen for testing the shared trackball engine and relaying to the desktop host.
struct TrackballRemoteView: View {
    private static let defaultPipelineDebugEnabled = true
    private static let pipelineLog = Logger(subsystem: "com.trackball-watch.app", category: "TrackballPipeline")
    private static let pipelineDebugEnabled = ProcessInfo.processInfo.environment["TRACKBALL_DEBUG_PIPELINE"]
        .map { $0 != "0" }
        ?? defaultPipelineDebugEnabled
    private static let fileTrace = CompanionTraceFileLogger(fileName: "trackball-companion-trace.log")

    @StateObject private var relay = WatchRelayService.shared
    @StateObject private var pairing = PairingService.shared
    @StateObject private var engine = TrackballInteractionEngine()
    @State private var packetBuilder = DebugTBPPacket()
    @State private var sendToDesktop = false
    @State private var showAdvancedTuning = false
    @State private var localTrackballFriction = 0.96
    @State private var virtualTrackballScale = 1.0
    @State private var lastGesture = "None"
    @State private var visibleFingerLocation: CGPoint?
    @State private var currentTrackballDiameter: CGFloat = 300
    @State private var isStreamingCoastTouch = false
    @State private var isPrimaryButtonHeld = false

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
    }

    private func trackballPanel(containerSize: CGSize, isLandscape: Bool) -> some View {
        let portraitHeight = min(max(260, containerSize.width - 40), containerSize.height * 0.52)
        return TrackballRemoteSurface(
            engine: engine,
            fingerLocation: visibleFingerLocation,
            hostLabel: currentHostLabel,
            canSwitchHosts: pairing.connections.count > 1,
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
                VStack(alignment: .leading, spacing: 6) {
                    sliderRow("Virtual Ball Size", value: $virtualTrackballScale, range: 0.55...10.0)
                    Text("Larger virtual ball increases cursor speed. Current: \(Int(currentVirtualTrackballDiameter.rounded())) pt")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
                }

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
            statRow("Virtual Ball", value: "\(Int(currentVirtualTrackballDiameter.rounded())) pt")
            statRow("Desktop Link", value: desktopLinkText)
            statRow("Packets Relayed", value: "\(relay.packetsRelayed)")
            statRow("Mouse Hold", value: isPrimaryButtonHeld ? "Down" : "Up")
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

    private var currentHostLabel: String {
        guard let active = pairing.activeConnection else { return "No Host" }
        let name = active.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? active.host : name
    }

    private var currentVirtualTrackballDiameter: CGFloat {
        let scaledDiameter = currentTrackballDiameter * CGFloat(virtualTrackballScale)
        return min(max(120, scaledDiameter), 900)
    }

    private func ensureDesktopRelayReady() {
        if !relay.isRunning {
            Self.fileTrace.log("relay.start")
            relay.start()
        }

        if let active = pairing.activeConnection {
            if !relay.isConnected(to: active) {
                Self.fileTrace.log("relay.connect host=\(active.host):\(active.port) id=\(active.deviceId)")
                relay.connectUDP(to: active)
            }
        }
    }

    private func switchToNextHost() {
        guard pairing.connections.count > 1 else { return }
        pairing.activateNextConnection()
        if sendToDesktop {
            ensureDesktopRelayReady()
        }
    }

    private func onDragChanged(_ value: DragGesture.Value, diameter: CGFloat) {
        visibleFingerLocation = value.location
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let events = engine.handleDragChanged(
            location: value.location,
            sphereCenter: center,
            sphereDiameter: currentVirtualTrackballDiameter
        )
        send(events)
    }

    private func onDragEnded(_ value: DragGesture.Value, diameter: CGFloat) {
        visibleFingerLocation = nil
        let events = engine.handleDragEnded(
            location: value.location,
            sphereDiameter: currentVirtualTrackballDiameter
        )
        send(events)
    }

    private func handleTapGesture() {
        tapFeedback.impactOccurred(intensity: 0.7)
        if isPrimaryButtonHeld {
            isPrimaryButtonHeld = false
            lastGesture = "Release"
        } else {
            lastGesture = "Tap"
        }
        sendGesture(.tap)
    }

    private func handleDoubleTapGesture() {
        doubleTapFeedback.impactOccurred(intensity: 0.9)
        lastGesture = "Double Tap"
        sendGesture(.doubleTap)
    }

    private func handleLongPressGesture() {
        impactFeedback.impactOccurred(intensity: 0.85)
        isPrimaryButtonHeld.toggle()
        lastGesture = isPrimaryButtonHeld ? "Hold Down" : "Hold Up"
        sendGesture(.longPress)
    }

    private func send(_ events: [TrackballEngineEvent]) {
        for event in events {
            switch event {
            case let .touch(phase, x, y, pressure):
                if phase == .began {
                    impactFeedback.impactOccurred(intensity: 0.45)
                    isStreamingCoastTouch = false
                }
                sendTouch(phase: phase, x: x, y: y, pressure: pressure)
            case .tap, .doubleTap, .longPress:
                break
            case .fling:
                // Fling gesture packets are no longer used for cursor motion.
                break
            }
        }
    }

    private func sendTouch(phase: TrackballEngineTouchPhase, x: Int16, y: Int16, pressure: UInt8) {
        guard sendToDesktop else { return }
        ensureDesktopRelayReady()
        let packet = packetBuilder.touch(phase: companionTouchPhase(phase), x: x, y: y, pressure: pressure)
        if Self.pipelineDebugEnabled {
            Self.pipelineLog.debug(
                "touch seq=\(self.packetBuilder.sequence, privacy: .public) phase=\(String(describing: phase), privacy: .public) x=\(x, privacy: .public) y=\(y, privacy: .public) pressure=\(pressure, privacy: .public) bytes=\(packet.count, privacy: .public)"
            )
        }
        Self.fileTrace.log("touch seq=\(packetBuilder.sequence) phase=\(phase) x=\(x) y=\(y) pressure=\(pressure) bytes=\(packet.count)")
        relay.relay(packet)
    }

    private func sendGesture(_ gesture: DebugGestureType) {
        guard sendToDesktop else { return }
        ensureDesktopRelayReady()
        Self.fileTrace.log("gesture \(gesture.rawValue)")
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

private final class CompanionTraceFileLogger {
    private let logger = Logger(subsystem: "com.trackball-watch.app", category: "TrackballPipeline")
    private let queue = DispatchQueue(label: "com.trackball.tracefile", qos: .utility)
    private let fileURL: URL
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var didReset = false

    init(fileName: String) {
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.fileURL = baseURL.appendingPathComponent(fileName)
    }

    func log(_ message: String) {
        queue.async { [self] in
            do {
                if !self.didReset {
                    try Data().write(to: self.fileURL, options: .atomic)
                    self.didReset = true
                }
                let line = "[\(self.formatter.string(from: Date()))] \(message)\n"
                if let data = line.data(using: .utf8) {
                    if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                        try handle.close()
                    } else {
                        try data.write(to: self.fileURL, options: .atomic)
                    }
                }
            } catch {
                self.logger.error("trace file write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct TrackballRemoteSurface: View {
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

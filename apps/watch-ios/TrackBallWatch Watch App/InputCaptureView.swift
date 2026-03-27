import SwiftUI
import WatchKit

/// Full-screen touch capture view.
/// Uses SpatialEventGesture (watchOS 10+) to capture touch with position data.
/// Coordinates are normalized to -32767...32767 range.
struct InputCaptureView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @StateObject private var gestureRecognizer = GestureRecognizer()

    /// Last known touch position (normalized).
    @State private var touchPos: CGPoint = .zero
    /// Whether touch is currently active.
    @State private var touching = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Visual feedback
                RoundedRectangle(cornerRadius: 8)
                    .fill(touching ? Color.blue.opacity(0.15) : Color.gray.opacity(0.05))
                    .animation(.easeInOut(duration: 0.1), value: touching)

                if touching {
                    Circle()
                        .fill(Color.blue.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .position(
                            x: (touchPos.x / 32767.0 + 1.0) / 2.0 * geo.size.width,
                            y: (touchPos.y / 32767.0 + 1.0) / 2.0 * geo.size.height
                        )
                        .animation(.interactiveSpring(), value: touchPos)
                }

                Text(touching ? "" : "Thumb here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .gesture(
                SpatialEventGesture(coordinateSpace: .local)
                    .onChanged { events in
                        handleSpatialEvents(events, in: geo.size)
                    }
                    .onEnded { events in
                        handleSpatialEventsEnded(events, in: geo.size)
                    }
            )
            .onAppear {
                // Forward all classified gestures; the host ignores types it does not use.
                // Previously we dropped swipe/fling — combined with a too-tight tap radius (500 in TBP space ≈ 1px), taps were misclassified and never forwarded, so clicks never reached the Mac.
                gestureRecognizer.onGestureDetected = { packet in
                    sessionManager.send(packet)
                }
            }
            .onDisappear {
                gestureRecognizer.onGestureDetected = nil
            }
        }
    }

    // MARK: - Event handling

    private func handleSpatialEvents(_ events: SpatialEventCollection, in size: CGSize) {
        guard let event = events.first else { return }

        let loc = event.location
        let normX = normalize(loc.x, range: 0...size.width)
        let normY = normalize(loc.y, range: 0...size.height)

        touchPos = CGPoint(x: normX, y: normY)

        let phase: TouchPhase
        switch event.phase {
        case .active:
            phase = touching ? .moved : .began
            touching = true
        default:
            phase = .ended
        }

        // Feed to gesture recognizer
        gestureRecognizer.onTouch(x: normX, y: normY, phase: phase)

        // Send raw touch for trackpad mode
        if sessionManager.mode == .trackpad || phase == .began || phase == .ended {
            let packet = TBPPacket.touch(
                touchId: 0,
                phase: phase,
                x: clampToInt16(normX),
                y: clampToInt16(normY),
                pressure: 0
            )
            sessionManager.send(packet)
        }

        if phase != .moved {
            let generator = WKHapticType.click
            WKInterfaceDevice.current().play(generator)
        }
    }

    private func handleSpatialEventsEnded(_ events: SpatialEventCollection, in size: CGSize) {
        touching = false
        let packet = TBPPacket.touch(
            touchId: 0,
            phase: .ended,
            x: clampToInt16(touchPos.x),
            y: clampToInt16(touchPos.y),
            pressure: 0
        )
        sessionManager.send(packet)
        gestureRecognizer.onTouchEnded()
    }

    /// Normalize a value in `range` to -32767...32767.
    private func normalize(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let t = (value - range.lowerBound) / span
        let clampedT = max(0, min(1, t))
        return (clampedT * 2.0 - 1.0) * 32767.0
    }

    /// `Int16(_: CGFloat)` traps on NaN/Inf or out-of-range; always clamp before packing TBP coords.
    private func clampToInt16(_ value: CGFloat) -> Int16 {
        guard value.isFinite else { return 0 }
        let d = max(min(Double(value), Double(Int16.max)), Double(Int16.min))
        return Int16(clamping: Int(d.rounded()))
    }
}

enum TouchPhase: UInt8 {
    case began = 1
    case moved = 2
    case ended = 3
    case cancelled = 4
}

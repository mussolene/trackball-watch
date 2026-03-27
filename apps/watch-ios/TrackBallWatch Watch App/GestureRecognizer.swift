import Foundation
import Combine

/// Watch-side gesture recognizer.
///
/// Runs on the watch to minimize the number of packets sent over WatchConnectivity.
/// Instead of sending every TOUCH_MOVED, it sends a single GESTURE packet
/// for tap, double-tap, long-press, swipe, and fling.
@MainActor
final class GestureRecognizer: ObservableObject {

    // MARK: - Configuration

    private let tapMaxDuration: TimeInterval = 0.3
    /// Max finger displacement for a tap, in TBP normalized coords (-32767…32767 per axis).
    /// One screen width maps to ~65534 units (~437 units per point at ~150pt), so 500 was ~1px — taps always became swipe/fling.
    private let tapMaxMovement: CGFloat = 12_000.0
    private let doubleTapWindow: TimeInterval = 0.4
    private let longPressMinDuration: TimeInterval = 0.8
    /// Avoid classifying a tap release as fling when velocity spikes briefly.
    private let flingMinSpeed: CGFloat = 2_500.0

    // MARK: - State

    private var touchBeganAt: Date = .now
    private var touchBeganPos: CGPoint = .zero
    private var lastPos: CGPoint = .zero
    private var lastPosTime: Date = .now
    private var velocityX: CGFloat = 0.0
    private var velocityY: CGFloat = 0.0
    private var lastTapTime: Date = .distantPast
    private var longPressTimer: Task<Void, Never>?
    private var isLongPressing = false

    var onGestureDetected: ((TBPPacket) -> Void)?

    // MARK: - Input

    func onTouch(x: CGFloat, y: CGFloat, phase: TouchPhase) {
        let pos = CGPoint(x: x, y: y)
        let now = Date.now

        switch phase {
        case .began:
            touchBeganAt = now
            touchBeganPos = pos
            lastPos = pos
            lastPosTime = now
            velocityX = 0
            velocityY = 0
            isLongPressing = false
            startLongPressTimer()

        case .moved:
            let dt = now.timeIntervalSince(lastPosTime)
            if dt > 0 {
                // Exponential moving average for velocity
                let alpha = 0.6
                velocityX = alpha * (x - lastPos.x) / dt + (1 - alpha) * velocityX
                velocityY = alpha * (y - lastPos.y) / dt + (1 - alpha) * velocityY
            }
            lastPos = pos
            lastPosTime = now

            // Cancel long press if moved too much (same scale as tapMaxMovement)
            let movement = distance(touchBeganPos, pos)
            if movement > tapMaxMovement * 1.2 {
                cancelLongPressTimer()
            }

        case .ended, .cancelled:
            break
        }
    }

    func onTouchEnded() {
        cancelLongPressTimer()
        guard !isLongPressing else { return }

        let duration = Date.now.timeIntervalSince(touchBeganAt)
        let movement = distance(touchBeganPos, lastPos)
        let speed = sqrt(velocityX * velocityX + velocityY * velocityY)

        if movement < tapMaxMovement && duration < tapMaxDuration {
            // Tap or double-tap
            let timeSinceLastTap = Date.now.timeIntervalSince(lastTapTime)
            if timeSinceLastTap < doubleTapWindow {
                emit(TBPPacket.gesture(type: .doubleTap, fingers: 1, param1: 0, param2: 0))
                lastTapTime = .distantPast
            } else {
                emit(TBPPacket.gesture(type: .tap, fingers: 1, param1: 0, param2: 0))
                lastTapTime = Date.now
            }
        } else if speed > flingMinSpeed {
            // Fling — send velocity vector
            let vx = Int16(clamping: Int(velocityX / 10))
            let vy = Int16(clamping: Int(velocityY / 10))
            emit(TBPPacket.gesture(type: .fling, fingers: 1, param1: vx, param2: vy))
        } else if movement >= tapMaxMovement {
            // Swipe
            let dir = swipeDirection(from: touchBeganPos, to: lastPos)
            let mag = Double(movement / 100)
            let param2: Int16
            if mag.isFinite {
                let clamped = max(min(mag, Double(Int16.max)), Double(Int16.min))
                param2 = Int16(clamping: Int(clamped.rounded()))
            } else {
                param2 = 0
            }
            emit(TBPPacket.gesture(type: .swipe, fingers: 1, param1: dir, param2: param2))
        }
    }

    // MARK: - Helpers

    private func startLongPressTimer() {
        longPressTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.longPressMinDuration ?? 0.8))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.isLongPressing = true
                let duration = Int16(clamping: Int((self?.longPressMinDuration ?? 0.8) * 1000))
                self?.emit(TBPPacket.gesture(type: .longPress, fingers: 1, param1: duration, param2: 0))
            }
        }
    }

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    private func emit(_ packet: TBPPacket) {
        onGestureDetected?(packet)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return sqrt(dx * dx + dy * dy)
    }

    /// Returns direction: 0=up, 1=right, 2=down, 3=left
    private func swipeDirection(from a: CGPoint, to b: CGPoint) -> Int16 {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if abs(dx) > abs(dy) {
            return dx > 0 ? 1 : 3
        } else {
            return dy > 0 ? 2 : 0
        }
    }
}

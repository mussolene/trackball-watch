import SwiftUI
import WatchKit

/// Handles Digital Crown rotation and maps it to TBP CROWN packets.
struct CrownHandlerModifier: ViewModifier {
    @EnvironmentObject var sessionManager: WatchSessionManager
    @State private var crownValue: Double = 0.0
    @State private var lastCrownValue: Double = 0.0
    @State private var crownVelocity: Double = 0.0
    @State private var lastCrownTime: Date = .now

    func body(content: Content) -> some View {
        content
            .digitalCrownRotation(
                $crownValue,
                from: -Double.infinity,
                through: Double.infinity,
                by: 1.0,
                sensitivity: .medium,
                isContinuous: true,
                isHapticFeedbackEnabled: true
            )
            .onChange(of: crownValue) { _, newValue in
                let now = Date.now
                let dt = now.timeIntervalSince(lastCrownTime)
                let delta = newValue - lastCrownValue

                if dt > 0 {
                    crownVelocity = delta / dt
                }

                lastCrownValue = newValue
                lastCrownTime = now

                // Clamp to i16 range
                let clampedDelta = Int16(clamping: Int(delta * 100))
                let clampedVelocity = Int16(clamping: Int(crownVelocity * 10))

                let packet = TBPPacket.crown(delta: clampedDelta, velocity: clampedVelocity)
                sessionManager.send(packet)
            }
    }
}

extension View {
    func crownScrollHandler() -> some View {
        modifier(CrownHandlerModifier())
    }
}

// MARK: - Long press: mode switch

struct ModeSwitchGesture: ViewModifier {
    @EnvironmentObject var sessionManager: WatchSessionManager

    func body(content: Content) -> some View {
        content.onLongPressGesture(minimumDuration: 0.8) {
            sessionManager.toggleMode()
        }
    }
}

extension View {
    func modeSwitchOnLongPress() -> some View {
        modifier(ModeSwitchGesture())
    }
}

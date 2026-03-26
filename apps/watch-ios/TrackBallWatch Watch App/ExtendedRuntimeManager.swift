import Foundation
import WatchKit

/// Manages WKExtendedRuntimeSession to keep the app alive during a tracking session.
///
/// Uses the `.workout` session type which provides the most background runtime.
@MainActor
final class ExtendedRuntimeManager: NSObject, ObservableObject {
    static let shared = ExtendedRuntimeManager()

    @Published var isRunning = false

    private var session: WKExtendedRuntimeSession?

    override private init() {
        super.init()
    }

    func startSession() {
        guard session == nil else { return }
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        s.start()
        session = s
    }

    func stopSession() {
        session?.invalidate()
        session = nil
        isRunning = false
    }
}

extension ExtendedRuntimeManager: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        Task { @MainActor in
            isRunning = true
        }
    }

    nonisolated func extendedRuntimeSession(
        _ session: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        Task { @MainActor in
            isRunning = false
            self.session = nil
            // Auto-restart after 2 seconds
            try? await Task.sleep(for: .seconds(2))
            startSession()
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        // Opportunity to stop gracefully before expiration
    }
}

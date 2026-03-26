import UIKit
import PushKit
import WatchConnectivity

class AppDelegate: NSObject, UIApplicationDelegate {
    private var pushKitRegistry: PKPushRegistry?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Register PushKit for VoIP wakeup (keeps app alive for background relay)
        setupPushKit()

        // Start WatchConnectivity session
        WatchRelayService.shared.start()

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Extend background execution for relay
        WatchRelayService.shared.beginBackgroundTask()
    }

    // MARK: - PushKit

    private func setupPushKit() {
        pushKitRegistry = PKPushRegistry(queue: .main)
        pushKitRegistry?.delegate = self
        pushKitRegistry?.desiredPushTypes = [.voIP]
    }
}

// MARK: - PKPushRegistryDelegate

extension AppDelegate: PKPushRegistryDelegate {
    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        // Send token to pairing server if needed
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "voip_push_token")
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // Wakeup: start relay if not running
        WatchRelayService.shared.start()
        completion()
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {}
}

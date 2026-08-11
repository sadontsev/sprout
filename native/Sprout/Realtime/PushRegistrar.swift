import Foundation
import UserNotifications

/// Remote-notification registration, and the silent push that vouches for a device token.
///
/// This app has never registered for remote notifications at all, which is why it has no device
/// token and why `/register-device` does not exist on the client — so every alert banner the server
/// produces (print finished, print halted, plate cool, drying done) has had nowhere to go.
///
/// The device token also matters for a second reason now. It is the only token kind Apple will
/// deliver a *silent* push to, which makes it the only one that can prove reachability: the relay
/// pushes a nonce to the token, and only the install that actually receives it can echo it back.
/// Push-to-start and per-activity tokens accept no silent push, so their values cannot be proven
/// this way — a limitation the design states rather than papers over.
@MainActor
final class PushRegistrar: NSObject {
    /// Nonces received by silent push, keyed by nothing: a nonce is single-use and short-lived, and
    /// the claim that consumes it is the very next thing that happens.
    private(set) var pendingVouchNonce: String?

    /// Called when a vouch nonce arrives, so a queued claim can be retried with it immediately
    /// rather than waiting for the next registration attempt.
    var onVouchNonce: ((String) -> Void)?

    /// Asks iOS for notification permission, then registers for remote notifications.
    ///
    /// Permission and registration are separate: a user who declines banners still gets a device
    /// token, and silent pushes still arrive. Refusing to register on a declined prompt would take
    /// vouching down with the banners, which are unrelated questions.
    func start() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        registerForRemoteNotifications()
    }

    /// Extracts a vouch nonce from a silent push payload, if it carries one.
    ///
    /// Static and pure so the parsing is testable: the alternative is a delegate callback that only
    /// runs on a device, which is how this kind of code goes untested.
    nonisolated static func vouchNonce(in userInfo: [AnyHashable: Any]) -> String? {
        guard let nonce = userInfo["vouch_nonce"] as? String, !nonce.isEmpty else { return nil }
        return nonce
    }

    /// Whether a payload is a vouch rather than a user-facing notification.
    nonisolated static func isVouch(_ userInfo: [AnyHashable: Any]) -> Bool {
        vouchNonce(in: userInfo) != nil
    }

    func handle(remoteNotification userInfo: [AnyHashable: Any]) {
        guard let nonce = Self.vouchNonce(in: userInfo) else { return }
        pendingVouchNonce = nonce
        onVouchNonce?(nonce)
    }

    func consumeVouchNonce() -> String? {
        defer { pendingVouchNonce = nil }
        return pendingVouchNonce
    }

    // MARK: - UIKit bridge

    private func registerForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
}

#if canImport(UIKit)
import UIKit

/// Bridges the UIKit notification callbacks SwiftUI does not surface.
///
/// The device token arrives here and nowhere else, and a silent push wakes the app through
/// `didReceiveRemoteNotification` — which is the path a vouch takes when the phone is locked in a
/// pocket, and the reason the pairing credentials had to move to `AfterFirstUnlock`.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    // Static, not instance, storage. `@UIApplicationDelegateAdaptor` constructs its OWN instance —
    // setting callbacks on a `shared` singleton leaves them on an object UIKit never calls, and the
    // symptom is simply that no device token ever arrives, with nothing logged anywhere.
    nonisolated(unsafe) static var onDeviceToken: ((String) -> Void)?
    nonisolated(unsafe) static var onVouchNonce: ((String) -> Void)?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.onDeviceToken?(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Deliberately not fatal and deliberately not retried here: without a device token this
        // install gets no banners and cannot vouch, but Live Activity push is a separate path and
        // must keep working.
        NSLog("[push] remote registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let nonce = PushRegistrar.vouchNonce(in: userInfo) else { return .noData }
        Self.onVouchNonce?(nonce)
        return .newData
    }
}
#endif

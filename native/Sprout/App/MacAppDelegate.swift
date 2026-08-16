#if os(macOS)
import AppKit
import SwiftUI

/// The macOS counterpart to `PushAppDelegate`.
///
/// It has exactly two jobs (§0), and deliberately no more — anything that can be expressed as a
/// SwiftUI scene or a `.commands` block belongs there, not here:
///
///  1. `application(_:open:)` — files dropped on the Dock icon, files opened from Finder, and
///     `bambu:` URLs. All three arrive here and nowhere else.
///  2. APNs token registration. `NSApplication.shared.registerForRemoteNotifications()` is the
///     macOS spelling of the call `PushRegistrar` makes on iOS.
///
/// Sprout is a normal app on macOS, not an agent: the activation policy stays `.regular` even
/// though there is a menu bar extra, so the app keeps its Dock icon and its menu bar.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Files handed to the app by the Dock, Finder or a `bambu:` URL. Static rather than instance
    /// storage for the same reason `PushAppDelegate` uses it: `@NSApplicationDelegateAdaptor`
    /// constructs its own instance, so an instance property set here is not the one the app reads.
    nonisolated(unsafe) static var onOpen: (@MainActor ([URL]) -> Void)?

    /// Buffers anything that arrives before a handler is installed. Launching by double-clicking a
    /// `.3mf` in Finder delivers the URL *before* the first scene appears, so without this the file
    /// that started the app would be the one file it silently ignored.
    nonisolated(unsafe) private static var pending: [URL] = []

    @MainActor
    static func setOpenHandler(_ handler: @escaping @MainActor ([URL]) -> Void) {
        onOpen = handler
        let queued = pending
        pending = []
        if !queued.isEmpty { handler(queued) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if let handler = MacAppDelegate.onOpen {
                handler(urls)
            } else {
                MacAppDelegate.pending.append(contentsOf: urls)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // §0's second job. The entitlement is real now — see `Sprout-macOS.entitlements` for why it
        // was silently absent for three builds (the iOS spelling `aps-environment` instead of the
        // macOS `com.apple.developer.aps-environment`).
        NSApplication.shared.registerForRemoteNotifications()

        // The consumer. It installs the `UNUserNotificationCenter` delegate — without one macOS
        // silently drops a notification posted while Sprout is frontmost, which is most of the
        // time these fire — and reads the current permission. It deliberately does NOT ask for
        // permission here: macOS shows its prompt exactly once, and a prompt on first launch,
        // before the user has even told the app about a printer, is the prompt everyone denies.
        // The Notifications pane asks, in context, with a button.
        MacNotificationController.shared.start()
        MacAppDelegate.onDeviceToken = { token in
            MacNotificationController.shared.deviceTokenArrived(token)
        }

        #if DEBUG
        MacWindowProbe.runIfRequested()
        #endif
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated { MacAppDelegate.onDeviceToken?(hex) }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        macPushLog.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Set by whatever consumes the token — `MacNotificationController`, wired in
    /// `applicationDidFinishLaunching` above. It used to be an unset hook, so the token arrived and
    /// was dropped.
    ///
    /// It is a hook rather than a direct call for the same reason `onOpen` is: this delegate is
    /// constructed by `@NSApplicationDelegateAdaptor` and cannot see anything SwiftUI owns.
    ///
    /// **What the consumer does with it is NOT what iOS does.** On iOS the token goes to Trellis so
    /// the relay can push alert banners; on macOS it is recorded and surfaced in Settings and goes
    /// no further, because Canopy will only push to a token that has been claimed with App Attest
    /// and the Mac profile grants no App Attest entitlement. See `MacNotificationController` for
    /// the whole chain — registering it anyway would leave the server pushing at a token that can
    /// never receive anything, with every component reporting success.
    nonisolated(unsafe) static var onDeviceToken: (@MainActor (String) -> Void)?

    /// Closing the last window should not quit: the menu bar extra (§5.1) is expected to keep
    /// working with the main window closed, and `⌘↩` from its panel reopens the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

import os
let macPushLog = Logger(subsystem: "com.mvks5.bambu", category: "mac-push")
#endif

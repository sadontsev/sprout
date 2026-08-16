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

    /// Set by whatever consumes the token. **Nothing does yet on macOS.**
    ///
    /// Registration above now succeeds and a token arrives, but `LiveActivityController` — the only
    /// thing that registers a token with Trellis — is `#if os(iOS)`, because its subject is a Live
    /// Activity. The Mac's consumer is the Notifications pane (1d), which turns a push into a
    /// `UNUserNotification`. Until that exists the token is received and dropped, which is why this
    /// stays an unset hook rather than a call into something.
    nonisolated(unsafe) static var onDeviceToken: (@MainActor (String) -> Void)?

    /// Closing the last window should not quit: the menu bar extra (§5.1) is expected to keep
    /// working with the main window closed, and `⌘↩` from its panel reopens the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

import os
let macPushLog = Logger(subsystem: "com.mvks5.bambu", category: "mac-push")
#endif

import SwiftUI

@main
struct SproutApp: App {
    @Environment(\.colorScheme) private var systemScheme
    /// Remote notifications arrive through UIKit callbacks SwiftUI does not surface: the device
    /// token, and the silent push that vouches for it.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    #if DEBUG
                    AttestCapture.runIfRequested()
                    #endif
                }
        }
    }
}

/// Applies the palette for the active colour scheme to the whole tree.
struct RootView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Shell()
            .environment(\.palette, Palette.forScheme(scheme))
    }
}

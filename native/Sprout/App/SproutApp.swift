import SwiftUI

@main
struct SproutApp: App {
    @Environment(\.colorScheme) private var systemScheme

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

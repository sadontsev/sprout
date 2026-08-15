import SwiftUI

@main
struct SproutApp: App {
    #if os(iOS)
    /// Remote notifications arrive through UIKit callbacks SwiftUI does not surface: the device
    /// token, and the silent push that vouches for it.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #else
    /// The macOS half of the same job, plus the two things only an NSApplicationDelegate sees:
    /// files opened from the Dock or Finder, and `bambu:` URLs.
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    /// The app's root state, owned by the App rather than by a view.
    ///
    /// On iOS this is the same single instance it always was — one `WindowGroup`, one `Shell`. On
    /// macOS it has to live here: the main window, the camera window, the menu bar extra and the
    /// Settings scene are four separate scenes that must share one `PrinterStatusStore`. §5.1 is
    /// explicit that the menu bar extra "must not open a second connection", and it has to keep
    /// working with the main window closed — neither is possible if the state hangs off a view.
    /// Not `private`: `macScenes` lives in `Views/Mac/MacScenes.swift` so this entry point stays a
    /// readable outline, and a `private` property is invisible to an extension in another file.
    @State var model = AppModel()

    /// The MakerWorld browse session. Owned here for the same reason it was owned by `Shell`: it
    /// must outlive the view that shows it, so leaving Explore and coming back returns to the
    /// results, query and scroll position you left behind (F2).
    @State var explore = ExploreModel()

    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            RootView(model: model, explore: explore)
                .task {
                    #if DEBUG
                    AttestCapture.runIfRequested()
                    #endif
                }
        }
        #else
        macScenes
        #endif
    }
}

#if os(iOS)
/// Applies the palette for the active colour scheme to the whole tree.
struct RootView: View {
    let model: AppModel
    let explore: ExploreModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Shell(model: model, explore: explore)
            .environment(\.palette, Palette.forScheme(scheme))
    }
}
#endif

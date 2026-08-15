#if os(macOS)
import SwiftUI

/// The macOS scene graph.
///
/// Kept out of `SproutApp` so the entry point stays a readable outline of "which platform, which
/// scenes" rather than a wall of modifiers.
///
/// All five scenes share ONE `AppModel`, injected from `SproutApp`. That is the whole reason the
/// model was hoisted out of `Shell`: §5.1 requires the menu bar extra to read the existing
/// `PrinterStatusStore` without opening a second connection, and to keep working with the main
/// window closed.
extension SproutApp {
    @SceneBuilder
    var macScenes: some Scene {
        // Explicitly identified so the menu bar extra's "Open Sprout" can reopen it by id after the
        // user has closed it — §5.1 requires the app to keep running with no main window.
        WindowGroup(id: "main") {
            MacRoot(model: model, explore: explore)
        }
        // §1: 1440×900 default, 1080×680 minimum. `.contentMinSize` is what makes the minimum real
        // — it stops the window being dragged below the content's own minimum, so the two collapse
        // rules in `MacWindow` only ever fire for split-screen and small external displays.
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { MacCommands() }

        // §5.2. One window per printer, keyed by printer id, so `openWindow(id:value:)` reuses the
        // existing window for the same machine instead of stacking duplicates.
        WindowGroup(id: "camera", for: Int.self) { $printerId in
            MacCameraWindow(model: model, printerId: printerId ?? model.printerId)
        }
        .defaultSize(width: 920, height: 592)
        .windowResizability(.contentSize)

        // §5.4 / 1g. Layers and STL are one window with a segment, not two: they show the same file
        // and the user switching between them should not be closing and opening windows.
        WindowGroup(id: "viewer", for: MacViewerRequest.self) { $request in
            MacViewerWindow(model: model, request: request)
        }
        .defaultSize(width: 960, height: 600)

        // §5.1. `.window` style rather than `.menu` because the panel carries a progress bar and
        // two controls; a menu of rows cannot draw either.
        MenuBarExtra {
            MacMenuBarPanel(model: model)
        } label: {
            MacMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // ⌘, comes from this scene. MacCommands deliberately does NOT declare one — two would give
        // the app two Settings items.
        Settings {
            MacSettingsView(model: model)
        }
    }
}
#endif

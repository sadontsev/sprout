#if os(macOS)
import SwiftUI

/// The macOS scene graph.
///
/// Kept out of `SproutApp` so the entry point stays a readable outline of "which platform, which
/// scenes" rather than a wall of modifiers. Scenes are added here as their phases land; the window
/// geometry below is §1 and does not change.
extension SproutApp {
    @SceneBuilder
    var macScenes: some Scene {
        WindowGroup {
            MacRoot(model: model, explore: explore)
        }
        // §1: 1440×900 default, 1080×680 minimum. `.contentMinSize` is what makes the minimum real
        // — it stops the window being dragged below the content's own minimum, so the two collapse
        // rules in `MacWindow` only ever fire for split-screen and small external displays.
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
}
#endif

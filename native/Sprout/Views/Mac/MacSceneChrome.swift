#if os(macOS)
import SwiftUI

/// The three things a **detached scene** needs before it can draw Sprout's design.
///
/// A `WindowGroup`, a `Settings` scene and a `MenuBarExtra` are separate scenes. They inherit
/// **nothing** from `MacRoot` — not the palette, not the density, not the appearance — so each has
/// to establish all three for itself. Getting two of the three is the failure this exists to stop,
/// because the missing one is invisible until someone looks at the running app on a Mac whose
/// system appearance disagrees with their Sprout theme.
///
/// **The half everyone forgets is `preferredColorScheme`.** `.environment(\.palette, …)` retints
/// what *Sprout* draws. It does not touch what **AppKit** draws — a `Toggle`'s capsule, a `Slider`'s
/// track and knob, a `TextField`'s bezel, a `Picker`, a focus ring, a `Menu`'s popup, a
/// `confirmationDialog`, a save panel. Those follow the window's `NSAppearance`, and a scene that
/// never states one keeps the *system's*. So a dark-theme Sprout on a light-appearance Mac drew a
/// white switch capsule and near-black system label text on a near-black card: a stray white oval,
/// and text that was simply not there.
///
/// That was found in `MacCameraWindow` by looking at a screenshot, fixed there, and a review then
/// found the identical defect in **three more scenes** — the viewer window, the Settings window and
/// the menu-bar panel. Three occurrences of one mistake is not three mistakes; it is a missing
/// abstraction. Hence this: the three modifiers cannot now be applied separately, so a fifth scene
/// cannot get two of them.
///
/// `systemScheme` is the caller's own `@Environment(\.colorScheme)`, needed for the `.system` case —
/// `ThemePreference.system` means "whatever the Mac is doing", and that is the only way to read it.
/// Passing `model.theme.colorScheme` straight to `preferredColorScheme` is correct for the same
/// reason: `nil` there means "follow the Mac", which is exactly what `.system` asks for.
extension View {
    func macSceneChrome(_ model: AppModel, systemScheme: ColorScheme) -> some View {
        self
            .environment(\.palette, Palette.forScheme(model.theme.colorScheme ?? systemScheme))
            .environment(\.metrics, .mac)
            .preferredColorScheme(model.theme.colorScheme)
    }
}
#endif

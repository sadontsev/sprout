#if os(macOS)
import SwiftUI

/// Values the main window publishes for `.commands` to act on.
///
/// `.commands` is attached to the SCENE, not to a view, so a menu item cannot reach into the
/// window's `@State` directly. `focusedSceneValue` is the supported bridge: the window publishes,
/// the command reads, and a command whose window is closed simply reads nil and disables itself —
/// which is exactly the behaviour wanted for `⌘R` with no window open.
extension FocusedValues {
    /// Refetches whatever section is on screen. §10: "⌘R refetches the current section and nothing
    /// else."
    var refreshSection: RefreshAction? {
        get { self[RefreshSectionKey.self] }
        set { self[RefreshSectionKey.self] = newValue }
    }

    /// The sidebar selection, so `⌘1`–`⌘6` can drive it.
    var selectedSection: Binding<TabKey>? {
        get { self[SelectedSectionKey.self] }
        set { self[SelectedSectionKey.self] = newValue }
    }

    /// `⌥⌘I`.
    /// Which printer `⌘0` should open the camera for.
    ///
    /// A focused value rather than a literal, for the reason every other item here is one: with no
    /// window open the command disables itself instead of acting on a printer that is not selected.
    /// This was hard-coded `0` — `AppModel`'s sentinel for "no printer confirmed yet" — so `⌘0`
    /// opened a second window for a printer that does not exist and sat on CONNECTING for ever.
    var cameraPrinterId: Int? {
        get { self[CameraPrinterKey.self] }
        set { self[CameraPrinterKey.self] = newValue }
    }

    var inspectorToggle: Binding<Bool>? {
        get { self[InspectorToggleKey.self] }
        set { self[InspectorToggleKey.self] = newValue }
    }
}

private struct CameraPrinterKey: FocusedValueKey { typealias Value = Int }
private struct RefreshSectionKey: FocusedValueKey { typealias Value = RefreshAction }
private struct SelectedSectionKey: FocusedValueKey { typealias Value = Binding<TabKey> }
private struct InspectorToggleKey: FocusedValueKey { typealias Value = Binding<Bool> }
#endif

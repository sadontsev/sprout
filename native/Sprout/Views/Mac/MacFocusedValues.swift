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
    var inspectorToggle: Binding<Bool>? {
        get { self[InspectorToggleKey.self] }
        set { self[InspectorToggleKey.self] = newValue }
    }
}

private struct RefreshSectionKey: FocusedValueKey { typealias Value = RefreshAction }
private struct SelectedSectionKey: FocusedValueKey { typealias Value = Binding<TabKey> }
private struct InspectorToggleKey: FocusedValueKey { typealias Value = Binding<Bool> }
#endif

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

    /// Pause / Resume / Stop for the menu bar. toolbars.md: "Make every toolbar item available as
    /// a command in the menu bar. Because people can customize the toolbar or hide it, it can't be
    /// the only place that presents a command." These lived only in the toolbar and the panel.
    var printerControls: PrinterControls? {
        get { self[PrinterControlsKey.self] }
        set { self[PrinterControlsKey.self] = newValue }
    }
}

/// What the main window can currently do to the printer, and whether the printer will accept it.
///
/// `isRunning` and `accepts` are SEPARATE on purpose — this is the trap CLAUDE.md names: the menu
/// bar panel once gated Pause on `vm.kind == .live`, which answers "is a print running?" and not
/// "will the printer accept a pause?", so in LAN mode Pause looked live and silently did nothing.
/// `accepts` reuses the same `Lan.isBlocked` gate the panel uses rather than a second predicate.
struct PrinterControls: Equatable {
    var isRunning: Bool
    var isPaused: Bool
    var accepts: (ActionId) -> Bool
    var run: (ActionId) -> Void

    /// Enabled only when the action is BOTH applicable and permitted.
    func enabled(_ action: ActionId) -> Bool { isRunning && accepts(action) }

    static func == (a: Self, b: Self) -> Bool {
        a.isRunning == b.isRunning && a.isPaused == b.isPaused
    }
}

private struct RefreshSectionKey: FocusedValueKey { typealias Value = RefreshAction }
private struct SelectedSectionKey: FocusedValueKey { typealias Value = Binding<TabKey> }
private struct InspectorToggleKey: FocusedValueKey { typealias Value = Binding<Bool> }
private struct PrinterControlsKey: FocusedValueKey { typealias Value = PrinterControls }
#endif

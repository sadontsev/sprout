#if os(macOS)
import Foundation

/// §1's automatic collapse rules, as arithmetic rather than as modifiers scattered through the view.
///
/// There is no user setting for this and there should not be: the rules exist so a window that is
/// narrower than the three-column layout wants degrades in a predictable order — the inspector goes
/// first because it is *about* the selection, the sidebar goes second because losing navigation is
/// worse than losing detail, and navigation is never actually lost because the toolbar grows a
/// section popup when the sidebar folds.
///
/// The window minimum is 1080 pt (§1) and `.windowResizability(.contentMinSize)` enforces it, so
/// **neither threshold is reachable by dragging the window edge**. They fire for split-screen, for
/// Stage Manager, and for small external displays — which is exactly why they need a test: nothing
/// in ordinary use will ever exercise them, so nothing in ordinary use will ever reveal them broken.
struct MacCollapse: Equatable, Sendable {
    /// May the inspector be on screen as a COLUMN? Below this the toggle still works, but it
    /// reveals the inspector as an overlay rather than stealing width from content.
    let inspectorFitsAsColumn: Bool
    /// May the sidebar be on screen? When false the toolbar must offer the section popup.
    let sidebarFitsAsColumn: Bool

    /// Below this the inspector stops being a column. 220 sidebar + 640 minimum content + 320
    /// inspector is 1180 exactly — so the rule is "the moment the three columns stop fitting at
    /// their stated widths", not a round number picked to look tidy.
    static let inspectorThreshold: CGFloat = 1180
    /// Below this the sidebar folds. 220 + 640 spare is 860; 980 leaves the content column real
    /// breathing room before the sidebar is taken away, because folding it is the more disruptive
    /// of the two.
    static let sidebarThreshold: CGFloat = 980

    static func forWidth(_ width: CGFloat) -> MacCollapse {
        MacCollapse(
            inspectorFitsAsColumn: width >= inspectorThreshold,
            sidebarFitsAsColumn: width >= sidebarThreshold
        )
    }

    /// Whether the toolbar has to carry a section popup, because the sidebar cannot.
    var needsToolbarSectionPopup: Bool { !sidebarFitsAsColumn }
}
#endif

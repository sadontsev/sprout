#if os(macOS)
import Foundation

/// Where the inspector's panes are drawn — the column, or beneath the section.
///
/// §1 auto-hides the inspector below 1180 pt, and `⌥⌘I` hides it at any width. Either way its panes
/// went with it, and nothing took their place: the triage card that says a nozzle is overdue, the
/// facts about the running job, the recent prints. The owner reported the camera vanishing this way
/// and the camera alone got a fallback — which fixed the symptom that was noticed and left the rest
/// of the column doing exactly the same thing.
///
/// So the rule generalises. It is deliberately the SAME shape as `MacCameraPlacement.owner`, and for
/// the same reason: the decision is made once, in one place, so the two views that act on it — the
/// column and the section — cannot read the fact separately and disagree. Two surfaces both
/// believing they own the panes is how the camera ends up with two live tiles.
///
/// The camera's own rule now falls out of this one rather than sitting beside it: when the panes
/// move, the camera tile inside them moves with them, so `MacPrinterSection` no longer carries a
/// bespoke camera fallback of its own. One mechanism, not two that must agree.
enum MacInspectorPlacement {

    /// Panes drawn as their own column, or inline under the section's content.
    enum Surface: Equatable, Sendable {
        /// The `.inspector` column on the trailing edge.
        case column
        /// Appended below the section, inside the section's own scroll view.
        case section
    }

    nonisolated static func owner(inspectorVisible: Bool) -> Surface {
        inspectorVisible ? .column : .section
    }

    /// HOW a section takes the panes when they fall back to it.
    ///
    /// Not a style preference — it follows the section's own layout, and getting it backwards is
    /// visibly broken rather than merely ugly:
    ///
    ///  - `.inline` — the section is a single top-level `ScrollView` over a stack of cards, so the
    ///    panes simply join the stack and scroll with it. Only Printer is built this way.
    ///  - `.drawer` — the section ends in a GREEDY scrolling child that owns the viewport: Files'
    ///    grid, Jobs' history, Hardware's segmented panes, Power's socket table, Explore's grid.
    ///    Appending a variable-height block after `maxHeight: .infinity` there is either clipped to
    ///    nothing or steals the height the section exists for, so the panes get their own bounded,
    ///    separately-scrolling region pinned to the bottom instead.
    ///
    /// The two look inconsistent side by side and are not: each is what its section's structure
    /// admits. A drawer on Printer would be a second scroll region inside a page that already
    /// scrolls as one.
    nonisolated static func host(for section: TabKey) -> Host {
        section == .printer ? .inline : .drawer
    }

    enum Host: Equatable, Sendable {
        case inline
        case drawer
    }

    /// Does `section` show its panes via `host` right now?
    ///
    /// The one predicate both hosts ask, so neither can decide for itself. `MacPrinterSection` asks
    /// about `.inline` and `MacInspectorDrawer` asks about `.drawer`; if they each assembled the
    /// answer from `owner` and `host` separately, the pair could both say yes — two copies of the
    /// panes, with two `.task`s behind them on Explore and Power — or both say no, which is the
    /// original disappearing-inspector bug returning by a new route.
    nonisolated static func shows(_ host: Host, section: TabKey, inspectorVisible: Bool) -> Bool {
        owner(inspectorVisible: inspectorVisible) == .section && self.host(for: section) == host
    }

    /// The drawer's height, from the height it has to share.
    ///
    /// Proportional with a ceiling, not a constant: the window minimum is 680 pt (§1) and a fixed
    /// 320 there would take nearly half the section, while on a tall display a fixed 320 is a thin
    /// strip under an ocean of grid. The floor matters too — below about 120 the drawer shows a
    /// header and a sliver, which reads as broken rather than compact.
    nonisolated static func drawerHeight(available: CGFloat) -> CGFloat {
        min(320, max(140, available * 0.42))
    }

    /// Should a detail panel lay its preview BESIDE its details rather than above them?
    ///
    /// The same panel has two homes with opposite proportions. The inspector **column** is 236–320 pt
    /// wide and as tall as the window: a vertical stack is the only thing that fits. The bottom
    /// **drawer** is as wide as the window and capped at `drawerHeight` — 320 pt — where a stack puts
    /// a square preview over the whole drawer and leaves the action row below the fold. Buttons you
    /// can only reach by scrolling, in the panel whose purpose is those buttons, is the same as not
    /// having them.
    ///
    /// The threshold is deliberately well above the widest column (320) so a column never trips it,
    /// and well below a plausible drawer, so the two placements never disagree about which they are.
    nonisolated static func detailIsHorizontal(width: CGFloat) -> Bool {
        width >= 520
    }

    // MARK: - The stored preference, and what may write it

    /// Is the inspector on screen as a column?
    ///
    /// A pure function of the user's wish and the width, with no third stored thing between them.
    /// The width used to be applied as a transition that wrote the preference — see
    /// `MacWindow.inspectorIsColumn` for what that cost.
    nonisolated static func columnShown(preference: Bool, fitsAsColumn: Bool) -> Bool {
        preference && fitsAsColumn
    }

    /// May a write to the inspector binding change the STORED preference?
    ///
    /// Only when the column could actually be shown. Below the threshold SwiftUI's own `.inspector`
    /// writes `false` back through the binding as it hides itself, and honouring that is
    /// indistinguishable from the user asking for it — which is how a narrow window came to leave a
    /// permanent `false` on disk.
    nonisolated static func acceptsPreferenceWrite(fitsAsColumn: Bool) -> Bool {
        fitsAsColumn
    }

    /// The drawer's height when its pane is only a placeholder.
    ///
    /// Enough for the "Nothing selected" line and its one sentence of explanation, and no more. The
    /// full height is for content; a placeholder that took it would be the fallback reserving a
    /// third of the window to report that there is nothing to report — measured on Explore, where it
    /// sat under the section's OWN empty state and filled the window with two of them.
    /// 150, not 104. The panes' placeholders are laid out for the COLUMN and carry a 40 pt top
    /// padding to sit them below its header; in a 104 pt drawer that left the title visible and its
    /// one explanatory sentence clipped, which reads as broken rather than compact. Measured against
    /// Explore's, the tallest: 40 padding + 22 icon + 8 + 17 title + 8 + two 15 pt lines.
    static let placeholderHeight: CGFloat = 150

    /// The width the panes are held to when they fall back into the content column.
    ///
    /// The column is 280–400 pt and every card in it is laid out for that. The content column is at
    /// least 640 pt and routinely far wider, so letting the panes stretch produces a 900 pt-wide
    /// "UP NEXT" card with one short line of text adrift in it — technically the same content, and
    /// visibly not the same design. 560 is `MacPrinterCameraTile.contentColumnWidth`, already chosen
    /// for exactly this job, so the fallback camera keeps the size it had before it was folded in
    /// here and the cards above and below it line up with it.
    static let sectionWidth: CGFloat = 560
}
#endif

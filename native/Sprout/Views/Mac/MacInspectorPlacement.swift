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

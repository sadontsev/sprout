#if os(macOS)
import SwiftUI

/// Does the inspector pane currently have anything to say?
///
/// Three of the six panes are ABOUT A SELECTION — Files, Jobs, Explore — and with nothing selected
/// they are a placeholder and nothing else. In the column that is fine: the column is 320 pt wide
/// and always there, and "Nothing selected · Click a model to see its versions" is exactly the right
/// thing to put in it.
///
/// In the DRAWER it is not fine, because the drawer spends HEIGHT, which the section needs. Measured
/// on Explore at 1120 pt: the section showed "Find something to print" over a drawer showing
/// "Nothing selected", two large empty states stacked, together filling the whole window with
/// nothing. The fallback exists to stop content disappearing, not to reserve a third of the window
/// for the news that there is none.
///
/// So a pane reports whether it is a placeholder, and the drawer sizes itself accordingly. It is a
/// `PreferenceKey` rather than a predicate the drawer could evaluate itself because the selections
/// live in the SECTIONS' own view state (`@SceneStorage` in `MacFilesSection`, `MacJobsSection`) —
/// nothing on `AppModel` knows them, and hoisting three selections into the model to answer a
/// layout question would be the tail wagging the dog.
///
/// **The pane stays mounted either way.** Only its height changes. Unmounting it would remove the
/// preference that decided to unmount it, and the drawer would oscillate.
struct MacInspectorHasContentKey: PreferenceKey {
    static let defaultValue = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value && nextValue()
    }
}

extension View {
    /// Mark this view as the pane's "nothing to show here" state.
    func macInspectorPlaceholder() -> some View {
        preference(key: MacInspectorHasContentKey.self, value: false)
    }
}
#endif

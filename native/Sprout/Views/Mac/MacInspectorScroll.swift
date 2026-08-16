#if os(macOS)
import SwiftUI

/// Wraps an inspector's panes in a `ScrollView`, or does not.
///
/// Six inspectors each needed the same `if scrolls` and it is the kind of conditional that gets
/// written five times correctly and once as `ScrollView { … }` unconditionally — which compiles,
/// renders, and produces a nested scroll view whose height is ambiguous and which shows a second
/// scrollbar only when the content is tall enough. One wrapper, one decision.
struct MacInspectorScroll<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if scrolls {
            ScrollView { content }
        } else {
            content
        }
    }
}
#endif

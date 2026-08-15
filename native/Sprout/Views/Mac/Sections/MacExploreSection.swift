#if os(macOS)
import SwiftUI

// PLACEHOLDER — filled in by the section pass. See docs/native-rewrite/18-mac-port-architecture.md.
struct MacExploreSection: View {
    let model: AppModel
    let explore: ExploreModel
    @Environment(\.palette) private var c

    var body: some View {
        Text(verbatim: "MacExploreSection")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.bg)
    }
}
#endif

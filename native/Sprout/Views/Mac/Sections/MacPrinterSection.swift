#if os(macOS)
import SwiftUI

// PLACEHOLDER — filled in by the section pass. See docs/native-rewrite/18-mac-port-architecture.md.
struct MacPrinterSection: View {
    let model: AppModel
    @Environment(\.palette) private var c

    var body: some View {
        Text(verbatim: "MacPrinterSection")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.bg)
    }
}
#endif

#if os(macOS)
import SwiftUI

// PLACEHOLDER — filled in by the camera pass (1c).
struct MacCameraWindow: View {
    let model: AppModel
    let printerId: Int
    @Environment(\.palette) private var c

    var body: some View {
        Text(verbatim: "Camera — printer \(printerId)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.bg)
    }
}
#endif

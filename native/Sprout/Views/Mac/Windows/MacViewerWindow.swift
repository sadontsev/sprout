#if os(macOS)
import SwiftUI

/// What the viewer window (1g) is showing. `Codable` + `Hashable` because `WindowGroup(for:)`
/// persists its value across launches, so a restored window can reopen the same file.
struct MacViewerRequest: Codable, Hashable, Identifiable {
    enum Mode: String, Codable, Hashable { case layers, model }
    let fileId: Int
    let name: String
    var mode: Mode = .layers

    var id: String { "\(fileId)-\(mode.rawValue)" }
}

// PLACEHOLDER — filled in by the viewer pass (1g).
struct MacViewerWindow: View {
    let model: AppModel
    let request: MacViewerRequest?
    @Environment(\.palette) private var c

    var body: some View {
        Text(verbatim: request.map { "Viewer — \($0.name)" } ?? "No file")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.bg)
    }
}
#endif

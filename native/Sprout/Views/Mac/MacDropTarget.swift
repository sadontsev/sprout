#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Accepts model files dropped **anywhere in the window** (§5.3).
///
/// Anywhere, not just over Files. A drop is a statement about the library, not about the screen you
/// happen to be looking at, and a target that only works on one of six sections is a target people
/// learn not to trust.
///
/// The accepted types are `UploadFileKind.all` — the same list the open panel filters by and the
/// same list `CFBundleDocumentTypes` declares. One source, so the three cannot disagree about what
/// Sprout takes; a drop the panel would have accepted but the window rejects is indistinguishable
/// from a broken app.
struct MacDropTarget: ViewModifier {
    let model: AppModel
    @Environment(\.palette) private var c
    @Environment(\.metrics) private var m

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let accepted = urls.filter(MacDropTarget.accepts)
                guard !accepted.isEmpty else {
                    // Rejected explicitly rather than silently. A drop that vanishes reads as a
                    // failed app; naming the four types it takes is the whole remedy.
                    model.toast = "Sprout takes .3mf, .gcode and .stl files."
                    return false
                }
                MacFileImport.ingest(accepted, model: model)
                model.isDropping = false
                return true
            } isTargeted: { targeted in
                // Published on the model rather than kept local, because the Files section draws
                // the dashed strip and this modifier sits on the window — two different views, one
                // fact. It is also what stops that strip being permanently visible, which would
                // claim a drop target on every other section too.
                model.isDropping = targeted
            }
            .overlay { if model.isDropping { dropVeil } }
    }

    /// Extension-based, deliberately. A URL dragged from Finder often arrives with no resolvable
    /// `UTType` — `gcode` and, on most systems, `3mf` are not registered types at all, which is why
    /// `UploadFileKind.all` has to mint them dynamically in the first place. Asking the file system
    /// for a content type here would reject exactly the files Sprout exists to open.
    static func accepts(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["3mf", "gcode", "stl"].contains { name.hasSuffix(".\($0)") }
    }

    private var dropVeil: some View {
        RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
            .strokeBorder(c.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(c.accentDim.opacity(0.35))
            .overlay {
                Text("Drop to add to your library")
                    .font(.system(size: m.cardTitle, weight: .semibold))
                    .foregroundStyle(c.t1)
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

extension View {
    /// §5.3's window-wide drop target.
    func macDropTarget(model: AppModel) -> some View {
        modifier(MacDropTarget(model: model))
    }
}
#endif

import SwiftUI

/// A library file's thumbnail, which is usually not a picture of the file.
///
/// Bambuddy renders these itself with unshaded matplotlib, so a sliced file and a raw `.stl` both
/// come back as a solid silhouette (`PlateImageProbe` explains why, and why that is Bambuddy working
/// as written rather than failing). This view does three things about that, in order:
///
/// 1. **Probe what arrived.** A real render is shown as-is. Imported `.3mf`s land here.
/// 2. **Borrow from the source.** A sliced file's own image is a silhouette, but the model it was
///    sliced from is usually in the same library with a good render — and it is one already-loaded
///    row away (`ThumbSource`). The borrowed image is probed too, so a wrong guess falls through
///    instead of showing a picture of some other model.
/// 3. **Say so.** If nothing better exists, the silhouette stays — it is honest about the shape, and
///    an empty rectangle would be worse — but it is labelled, so nobody reads it as a bad render of
///    their model. Per this repo's rule: a user should not have to discover a limitation by
///    hitting it.
///
/// The grid never *renders* anything to fix this. A sliced file's toolpaths are ~78 MB uncompressed
/// (21 MB over the wire) for one real file measured here, so rendering per tile would pull a
/// gigabyte to scroll fifty files. Rendering stays where the user asked for it — the wizard and the
/// viewers.
struct LibraryThumb: View {
    let file: LibraryFile
    /// The rows already on screen. Read-only, and only to find the file this one was sliced from.
    let library: [LibraryFile]
    let client: BambuddyClient
    let token: String
    var glyphSize: CGFloat = 26
    /// Whether there is room to explain a silhouette. False in the 44pt list rows, where a badge
    /// would cover the image it is describing.
    var showsProvenance: Bool = true

    @Environment(\.palette) private var c
    @State private var image: PlatformImage?
    @State private var isSilhouette = false
    @State private var resolved = false

    var body: some View {
        // `Color.clear` owns the layout size, and the image sits in ITS overlay.
        //
        // Not a ZStack containing the image: a `.resizable().aspectRatio(.fill)` image is flexible
        // and OVERFLOWS the frame it is handed, and a stack sizes itself to its children — so the
        // stack grew taller than the tile and anything anchored to `.bottomLeading` landed below the
        // visible area. `.clipped()` does not fix that; it clips drawing, not layout. Diagnosed by
        // giving this view a red border and seeing only its left and right edges.
        Color.clear
            .overlay {
                if let image {
                    Image(platform: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else if resolved {
                    Image(systemName: LibraryFileCaps.hasGcode(file) ? "shippingbox" : "doc")
                        .font(.system(size: glyphSize))
                        .foregroundStyle(c.t3)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if isSilhouette, showsProvenance, image != nil { outlineBadge }
            }
            .animation(Motion.standard(0.18), value: image != nil)
            // Keyed on the id, not the file: the row is recycled onto a different file during a
            // scroll, and without the reset the previous model's picture sits under the new name.
            .task(id: file.id) {
                image = nil
                isSilhouette = false
                resolved = false
                await resolve()
            }
    }

    /// Mono and muted, matching the app's other in-frame labels. Loud enough to notice while looking
    /// at the tile, quiet enough not to shout on a grid where several files are silhouettes.
    private var outlineBadge: some View {
        Text("OUTLINE")
            .scaledMono(9, weight: .bold)
            .foregroundStyle(c.t3)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(c.s2.opacity(0.85)))
            .padding(6)
            .help(Self.explanation(borrowedFailed: triedSource))
    }

    @State private var triedSource = false

    /// Why this tile is a silhouette. States a fact about the image in hand — never a guess about
    /// which of several things went wrong on the server.
    static func explanation(borrowedFailed: Bool) -> String {
        borrowedFailed
            ? "Bambuddy drew this outline itself. The file it was sliced from has no picture either."
            : "Bambuddy drew this outline itself. The slicer never rendered a picture of this plate."
    }

    private func resolve() async {
        guard let url = client.fileThumbUrl(file.id, token: token, thumbnailPath: file.thumbnailPath)
        else {
            resolved = true
            return
        }

        let primary = await ThumbCache.shared.classified(for: url)
        guard !Task.isCancelled else { return }

        if let primary, primary.verdict.depictsModel {
            image = primary.image
            resolved = true
            return
        }

        // The primary is a silhouette (or unreadable). Try the model it was sliced from before
        // settling for it.
        if let source = ThumbSource.sourceCandidate(for: file, in: library),
           let sourceUrl = client.fileThumbUrl(source.id, token: token,
                                               thumbnailPath: source.thumbnailPath) {
            triedSource = true
            let borrowed = await ThumbCache.shared.classified(for: sourceUrl)
            guard !Task.isCancelled else { return }
            if let borrowed, borrowed.verdict.depictsModel {
                image = borrowed.image
                resolved = true
                return
            }
        }

        // Nothing better exists. Keep the silhouette and label it — it still carries the shape.
        image = primary?.image
        isSilhouette = primary != nil
        resolved = true
    }
}

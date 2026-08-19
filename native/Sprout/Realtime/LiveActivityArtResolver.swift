#if os(iOS)
import SwiftUI
import UIKit

/// Puts the images a Live Activity card needs into the App Group, and hands back their URIs.
///
/// A widget cannot read the app's sandbox, so a picture reaches a card only as a file in the shared
/// container (see `LiveActivityArt`). This is the thing that actually writes them — the piece that
/// was missing, which is why every card this app has ever shown fell to a generic SF Symbol where the
/// print was meant to be.
///
/// Lives beside the controller rather than inside it because it needs the LIBRARY and a CAMERA TOKEN,
/// neither of which the controller has or should acquire: `LiveActivityController.sync` takes a
/// printer id, a view model and a status, and adding a network client to it would make the card
/// subsystem depend on the browsing subsystem. `AppModel` already owns both, so it resolves the art
/// and passes URIs down as plain strings.
@MainActor
final class LiveActivityArtResolver {

    /// URIs already resolved, keyed by printer. Held so the 4-second sync loop does not re-download
    /// and re-write a PNG it wrote four seconds ago.
    private var cached: [Int: Resolved] = [:]
    /// Whether the brand glyph has been written this launch. One file, written once.
    private var glyphURI: String?

    struct Resolved: Equatable {
        var jobName: String
        var modelUri: String
    }

    /// The nozzle mark, for the leading-slot fallback and the extrusion bar's rider.
    ///
    /// Rendered from the asset catalog rather than shipped as a second PNG, so the card and the app
    /// can never show two different vintages of the brand mark. Drawn WHITE: the card background is
    /// fixed dark glass (`activityBackgroundTint`), and a template image is not a thing a widget can
    /// tint from a file URI.
    func glyph() -> String {
        if let glyphURI { return glyphURI }
        let existing = LiveActivityArt.existingURI(name: LiveActivityArt.glyphName)
        if !existing.isEmpty {
            glyphURI = existing
            return existing
        }
        guard let source = UIImage(named: "TabNozzle") else { return "" }
        let side: CGFloat = 96      // 15x20 pt at 3x, with room to spare for the 56 pt slot
        let size = CGSize(width: side * (source.size.width / max(source.size.height, 1)), height: side)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            source.withRenderingMode(.alwaysTemplate)
                .withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = rendered.pngData() else { return "" }
        let uri = LiveActivityArt.write(data, name: LiveActivityArt.glyphName)
        glyphURI = uri
        return uri
    }

    /// The plate render for the job `printerId` is running, written into the App Group.
    ///
    /// Best-effort by design: no library listing, no match, no token, no network — every one of those
    /// returns "" and the card shows the brand glyph instead. A missing picture is a smaller failure
    /// than a delayed card, so nothing here is allowed to block `sync`.
    func plate(printerId: Int, jobName: String, library: [LibraryFile], client: BambuddyClient?, token: String?) async -> String {
        guard !jobName.isEmpty else { return "" }
        // Same job as last time and already written — the common case on a 4-second loop.
        if let hit = cached[printerId], hit.jobName == jobName, !hit.modelUri.isEmpty {
            return hit.modelUri
        }
        guard let client, let token, !library.isEmpty,
              let file = PrintArt.artFile(jobName: jobName, in: library),
              let url = client.fileThumbUrl(file.id, token: token, thumbnailPath: file.thumbnailPath) else {
            return ""
        }
        let name = LiveActivityArt.plateName(printerId: printerId, fileName: jobName)
        // Written already this launch for this job? Then the file is on disk and nothing needs the
        // network.
        let existing = LiveActivityArt.existingURI(name: name)
        if !existing.isEmpty {
            cached[printerId] = Resolved(jobName: jobName, modelUri: existing)
            return existing
        }
        // Through `ThumbCache`, so a plate the Files grid already fetched is not fetched again — the
        // library thumbnail endpoint is token-gated and the token rotates hourly.
        guard let image = await ThumbCache.shared.image(for: url),
              let data = image.pngData() else { return "" }
        let uri = LiveActivityArt.write(data, name: name)
        cached[printerId] = Resolved(jobName: jobName, modelUri: uri)
        // Everything this launch still refers to, plus the glyph, survives; the rest is last week's
        // prints taking up space nobody can see.
        LiveActivityArt.sweepPlates(keeping: Set(cached.values.map { ($0.modelUri as NSString).lastPathComponent }))
        return uri
    }

    /// Drop a printer's cache when its card ends, so the next print re-resolves rather than showing
    /// the previous job's plate.
    func forget(printerId: Int) {
        cached[printerId] = nil
    }
}
#endif

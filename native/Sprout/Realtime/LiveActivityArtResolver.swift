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

    /// The printer's own file listing, fetched by this type when the app has not browsed Printer SD.
    ///
    /// **Without this the plate almost never resolved.** `sdFiles` is passed down from
    /// `LibraryStore.printerList`, which is only populated once the user opens the Printer SD segment
    /// — so on a normal launch the second rung of the ladder had an empty list to search and every
    /// card fell back to the brand glyph. Measured against the live machine: the running job was on
    /// the card and its plate render returned 200 the whole time.
    private var sdCache: [Int: [PrinterFile]] = [:]

    /// Job names the card has already been listed for, per printer.
    ///
    /// `sdCache` alone made a stale listing permanent: a print sent from Studio or Handy lands its
    /// file on the card AFTER the app cached the listing, so the job was missing from the copy we
    /// held and was never looked for again — brand glyph for the whole session, cured only by
    /// relaunching. See `PrintArt.shouldListCard`.
    private var sdAsked: [Int: Set<String>] = [:]

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
    func plate(
        printerId: Int,
        jobName: String,
        library: [LibraryFile],
        sdFiles: [PrinterFile] = [],
        client: BambuddyClient?,
        token: String?
    ) async -> String {
        guard !jobName.isEmpty else { return "" }
        // Same job as last time and already written — the common case on a 4-second loop.
        if let hit = cached[printerId], hit.jobName == jobName, !hit.modelUri.isEmpty {
            return hit.modelUri
        }
        guard let client else { return "" }

        // Two sources, in order. The LIBRARY first — its thumbnails are the richer image, and
        // `ThumbSource` can borrow the source model's render when the sliced file's own is a flat
        // silhouette. Then the printer's OWN CARD, which is where most jobs actually come from.
        //
        // The second rung is not a nicety. Measured on the live machine: the running job was
        // `kid34_slide_A_76`, no library row matched it, and `/kid34_slide_A_76.gcode.3mf` was sitting
        // on the card with a plate render that returns 200. A library-only ladder would have shown the
        // brand glyph for every print not started from the library.
        //
        // The two rungs authenticate DIFFERENTLY and that is easy to get backwards: a library
        // thumbnail is gated by the camera stream token in `?token=` and 401s on the header, while the
        // printer's plate render is gated by the `X-API-Key` HEADER and 401s on the bare URL.
        var url: URL?
        var headers: [String: String] = [:]
        if let token, !library.isEmpty,
           let file = PrintArt.artFile(jobName: jobName, in: library) {
            url = client.fileThumbUrl(file.id, token: token, thumbnailPath: file.thumbnailPath)
        } else if let entry = PrintArt.matchSd(
            jobName: jobName,
            in: await sdListing(printerId, job: jobName, given: sdFiles, client: client)) {
            url = client.printerPlateThumbUrl(printerId, path: entry.path)
            headers = client.authHeaders()
        }
        guard let url else { return "" }
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
        guard let image = await ThumbCache.shared.image(for: url, headers: headers),
              let data = image.pngData() else { return "" }
        let uri = LiveActivityArt.write(data, name: name)
        cached[printerId] = Resolved(jobName: jobName, modelUri: uri)
        // Everything this launch still refers to, plus the glyph, survives; the rest is last week's
        // prints taking up space nobody can see.
        LiveActivityArt.sweepPlates(keeping: Set(cached.values.map { ($0.modelUri as NSString).lastPathComponent }))
        return uri
    }

    /// The SD root listing: whatever already contains this job, else one fetch per job.
    ///
    /// Root only. A job in a subfolder will not match and falls back to the glyph, which is the
    /// honest outcome — walking the whole card on a 4-second loop to chase one thumbnail is a lot of
    /// requests for a picture.
    ///
    /// The "one fetch per JOB" part is `PrintArt.shouldListCard`, and it is the difference between
    /// this rung working for a print sent from Studio and it working only if the app happened to
    /// launch after the file arrived.
    private func sdListing(_ printerId: Int, job: String, given: [PrinterFile],
                           client: BambuddyClient) async -> [PrinterFile] {
        if PrintArt.matchSd(jobName: job, in: given) != nil { return given }
        let cached = sdCache[printerId]
        guard PrintArt.shouldListCard(job: job, browsed: given, cached: cached,
                                      alreadyAsked: sdAsked[printerId]?.contains(job) == true) else {
            return cached ?? given
        }
        sdAsked[printerId, default: []].insert(job)
        let files = (try? await client.listPrinterFiles(printerId, path: "/"))?.files ?? []
        // Stored even when empty, so an unreachable printer is asked once per job rather than every
        // tick — the memo above is what keeps "empty" from meaning "forever".
        sdCache[printerId] = files
        return files
    }

    /// Drop a printer's cache when its card ends, so the next print re-resolves rather than showing
    /// the previous job's plate.
    func forget(printerId: Int) {
        cached[printerId] = nil
        sdCache[printerId] = nil
    }
}
#endif

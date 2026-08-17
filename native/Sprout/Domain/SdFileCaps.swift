import Foundation

/// What an entry on the printer's own storage can actually be asked for.
///
/// The sibling of `LibraryFileCaps`, and it exists for the same reason: the Files section, its
/// context menu and the inspector all ask these questions, and the first time they were asked in two
/// places the answers drifted. Every predicate here is named for the question it answers rather than
/// for the thing it happens to test.
///
/// **This type was written to fix the INVERSE of CLAUDE.md's recurring bug.** That table records
/// surfaces offering what the backend will refuse. The Mac SD panel had the mirror-image defect — it
/// refused six things the backend serves, and said so in copy that read as a platform fact:
///
/// > "Printing and layer preview work on library files, not on the printer's own storage."
///
/// Half of that is true and half of it is false. `GET /printers/{id}/files/gcode?path=…` exists,
/// answers for a `.gcode.3mf` on the card, and iOS has scrubbed layers straight off the SD card all
/// along. Only *printing* is genuinely unavailable. A sentence that bundles a real limitation with an
/// invented one teaches a user to disbelieve both, so the two are separate predicates below with
/// separate reasons.
///
/// The three that are genuinely absent are absent because **no endpoint takes a printer path** — not
/// because an SD entry is second-class. `BambuddyClient`'s SD block is seven members
/// (list · download · plate-thumbnail · plates · delete · gcode-path · gcode-text) and there is no
/// write operation among them other than `DELETE`.
enum SdFileCaps {

    // MARK: - What the printer will serve

    /// Whether the layer viewer can scrub this entry.
    ///
    /// `isSliced3mf`, so `.gcode.3mf` and not any `.3mf` — the same distinction `LibraryFileCaps`
    /// keeps between `isSliced` and `hasGcode`, and for the same reason: a plain project 3MF carries
    /// no toolpaths and the endpoint answers nothing useful for one.
    static func canViewLayers(_ pf: PrinterFile) -> Bool {
        !pf.isDirectory && PrinterFiles.isSliced3mf(pf.name)
    }

    /// Whether this entry can be played as video.
    ///
    /// `.mp4` only — `PrinterFiles.isPlayableVideo` excludes the `.avi` older firmwares wrote,
    /// because AVFoundation will not play those and offering Play for one is a dead control.
    static func canPlay(_ pf: PrinterFile) -> Bool {
        !pf.isDirectory && PrinterFiles.isPlayableVideo(pf.name)
    }

    /// Whether the bytes can be fetched — which is every file and no folder.
    ///
    /// The download endpoint is authenticated by the `X-API-Key` **header**; the bare URL 401s. That
    /// is the opposite of the library's thumbnails, which are gated by a stream token in the query
    /// and reject the header. Anything rendering an SD image or fetching an SD file must send headers.
    static func canDownload(_ pf: PrinterFile) -> Bool {
        !pf.isDirectory
    }

    /// Whether deleting is possible. Every entry, folders included — the endpoint takes a path.
    ///
    /// Present as a named predicate rather than inlined `true` so the SD surface reads as a list of
    /// capabilities with one obvious gap, instead of a list of gaps with one exception.
    static func canDelete(_ pf: PrinterFile) -> Bool {
        !pf.isDirectory
    }

    // MARK: - What it will not

    /// Printing from the printer's own storage: **never**, and not for lack of a control.
    ///
    /// There is no path-based print or enqueue endpoint. `BambuddyClient.enqueue` takes arbitrary
    /// JSON, but every caller passes a `library_file_id` or an `archive_id`, and the print sheet is
    /// built on `LibraryFile` throughout — an SD entry has only a path. Whether Bambuddy could grow
    /// such an endpoint is a different question from whether this app may offer the button today.
    ///
    /// A function rather than a constant so the call sites read the same as every other capability
    /// here, and so a future endpoint changes one body instead of hunting inlined `false`s.
    static func canPrint(_ pf: PrinterFile) -> Bool { false }

    /// The 3D mesh view: also never, for a narrower reason than printing.
    ///
    /// The mesh viewer is an STL parser, and the only server-side mesh export
    /// (`/library/files/{id}/mesh`) is keyed by library id. Nothing converts a printer path into a
    /// mesh, so this is refused even for a file whose name ends in `.stl` — the printer's card holds
    /// sliced output, not source models, and an STL that did land there could not be fetched as a
    /// mesh anyway.
    static func canView3D(_ pf: PrinterFile) -> Bool { false }

    // MARK: - The reasons, said once

    /// Why `Print…` is missing, in the words the inspector prints under the buttons.
    ///
    /// Deliberately about the SERVER rather than about the app: "this app can't" invites "then fix
    /// the app", while the true shape is that the printer's storage is not addressable by the print
    /// API at all. The remedy is real and worth naming, because a user holding a file on the card
    /// genuinely can print it — by adding it to the library first.
    static let noPrintNote =
        "Printing takes a library file — the print API has no way to address a file on the card. Add it to the library to print it."

    /// Why there is no 3D view. Two facts, because either alone invites the wrong fix.
    static let noMeshNote =
        "The 3D view reads an STL mesh, and the printer’s storage holds sliced output rather than source models."

    /// Why `View layers` is missing on a file that is not a sliced 3MF. Mirrors
    /// `MacViewerCopy.noLayers` for the library, so one refusal is not worded two ways.
    static let noLayersNote =
        "View layers needs toolpaths, and only a sliced .gcode.3mf has them."

    // MARK: - The picture

    /// Which image, if any, represents this entry.
    ///
    /// Three cases rather than an optional URL because the three come from genuinely different
    /// places, and a caller that cannot tell them apart cannot pick the right fallback: a plate
    /// render is a *rendering of the print*, a poster is a *frame the printer saved*, and a glyph is
    /// the honest absence of both.
    enum Preview: Equatable {
        /// A sliced 3MF's plate, rendered by the server: `/files/plate-thumbnail/{n}?path=…`.
        case plate
        /// A video's poster JPEG, which the printer writes beside the recording. Carries the path to
        /// fetch, since it is a DIFFERENT file from the entry itself.
        case poster(path: String)
        /// Nothing to show. The row's symbol is the whole answer.
        case glyph
    }

    /// The preview for one entry.
    ///
    /// A folder is `glyph` even inside `/timelapse`: the poster convention names a file beside a
    /// recording, and asking for the poster of a directory fetches nothing.
    ///
    /// The poster is offered for any playable video rather than only inside a media folder. That is
    /// deliberate and it is NOT the recurring bug wearing a hat: a preview is not an affordance. A
    /// missing poster falls back to the glyph with no error and no dead control, whereas gating on
    /// the parent folder would hide the poster for a recording the user had moved. The gate belongs
    /// on `canPlay`, which is a real action, and that one is exact.
    static func preview(_ pf: PrinterFile) -> Preview {
        guard !pf.isDirectory else { return .glyph }
        if PrinterFiles.isSliced3mf(pf.name) { return .plate }
        if PrinterFiles.isPlayableVideo(pf.name) { return .poster(path: PrinterFiles.mediaThumbPath(pf.path)) }
        return .glyph
    }

    /// What a card or row is called.
    ///
    /// A recording's filename is a timestamp the printer wrote (`video_2026-07-05_15-16-02.mp4`), and
    /// `mediaLabel` turns that into `Jul 5, 15:16`. Everything else keeps its own name: a
    /// `PrinterFile`'s `name` **is** its display name — unlike a `LibraryFile`, it is not
    /// percent-encoded and has no `printName` alternative.
    static func displayName(_ pf: PrinterFile) -> String {
        PrinterFiles.isPlayableVideo(pf.name) ? PrinterFiles.mediaLabel(pf.name) : pf.name
    }

    /// The short type badge on a card.
    ///
    /// A sliced print is `GCODE.3MF`, **not** `3MF`, which is what the bare path extension gives —
    /// and the wrong one of those is the isSliced/hasGcode confusion drawn on screen. The library card
    /// beside it shows `fileType` verbatim and says `GCODE.3MF` for the same file; two badges reading
    /// differently for one kind of file is how a user learns the badge means nothing.
    static func typeLabel(_ pf: PrinterFile) -> String {
        if pf.isDirectory { return "FOLDER" }
        if PrinterFiles.isSliced3mf(pf.name) { return "GCODE.3MF" }
        return (pf.name as NSString).pathExtension.uppercased()
    }

    /// The row/card symbol. The single source for both layouts, so a file cannot be a `shippingbox`
    /// in the list and a `doc` in the grid.
    static func symbol(_ pf: PrinterFile) -> String {
        if pf.isDirectory { return PrinterFiles.isMediaFolder(pf.path) ? "film" : "folder" }
        if PrinterFiles.isSliced3mf(pf.name) { return "shippingbox" }
        if PrinterFiles.isPlayableVideo(pf.name) { return "film" }
        return "doc"
    }
}

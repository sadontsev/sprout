import Foundation

/// Where a library file's thumbnail should come from, when its own is a flat silhouette.
///
/// A sliced file's picture is Bambuddy's unshaded matplotlib render (see `PlateImageProbe`), but the
/// model it was sliced FROM is usually sitting in the same library with a perfectly good one — a
/// MakerWorld import carries its own embedded thumbnail. Measured on this server: `cr.3mf` (id 40)
/// returns a detailed shaded render, and all three `cr.gcode.3mf` sliced from it (ids 41–43) return
/// the green ellipse. Borrowing the source's image costs nothing: it is the same host, the same
/// token, and the row is already in the list on screen.
///
/// **There is no parent link in the API.** Two fields look like one and are not:
///
/// - `sliced_from_library_file_id` does not exist. It was proposed during design; the live schema
///   has no such column.
/// - `slicedForModel` is the PRINTER model (`X1C`, `H2C`), not the source file.
/// - `variant_group_id` exists in the database and is `NULL` on every row.
///
/// So the link is derived from the filename, which the slicer's naming makes reliable: slicing `X.3mf`
/// writes `X.gcode.3mf`. That is a heuristic, and it is never trusted on its own — the borrowed image
/// is probed too, and is used only if it actually contains shading. A wrong guess degrades to the
/// silhouette we already had rather than to a picture of the wrong model.
enum ThumbSource {
    /// The filename a sliced file was produced from, or nil if this is not a sliced name.
    ///
    /// Percent-decodes first: some rows arrive URL-encoded from the import path
    /// (`Adapter%20hexagon%20for%20electric%20drill.gcode.3mf` is a real row here), and comparing
    /// raw against decoded would miss its source.
    static func sourceStem(of filename: String) -> String? {
        let name = filename.removingPercentEncoding ?? filename
        let suffix = ".gcode.3mf"
        guard name.count > suffix.count,
              name.lowercased().hasSuffix(suffix) else { return nil }
        return String(name.dropLast(suffix.count))
    }

    /// Normalised comparison form, so an encoded row matches its decoded sibling.
    private static func normalised(_ filename: String) -> String {
        (filename.removingPercentEncoding ?? filename).lowercased()
    }

    /// The file `sliced` was most likely produced from, chosen from `library`.
    ///
    /// Prefers a `.3mf` over a `.stl`: an imported `.3mf` embeds a real render, whereas an `.stl`
    /// only ever gets Bambuddy's own silhouette, so borrowing from one would swap a blob for a blob.
    ///
    /// Among equals, the **nearest preceding id** wins. Slicing happens after upload, so the source
    /// is the closest row before the slice — which is what disambiguates a library holding two
    /// separate `3 colour benchy.3mf` (ids 48 and 53) and a slice of each (49 and 54). Picking
    /// "first match" would give both slices the same source and get one of them wrong.
    static func sourceCandidate(for sliced: LibraryFile, in library: [LibraryFile]) -> LibraryFile? {
        guard let stem = sourceStem(of: sliced.filename) else { return nil }
        let wanted3mf = normalised(stem + ".3mf")
        let wantedStl = normalised(stem + ".stl")

        let matches = library.filter { candidate in
            guard candidate.id != sliced.id else { return false }
            // A sliced file is never a source — otherwise one blob borrows from another.
            guard sourceStem(of: candidate.filename) == nil else { return false }
            guard candidate.thumbnailPath != nil else { return false }
            let name = normalised(candidate.filename)
            return name == wanted3mf || name == wantedStl
        }
        guard !matches.isEmpty else { return nil }

        let threeMF = matches.filter { normalised($0.filename) == wanted3mf }
        let pool = threeMF.isEmpty ? matches : threeMF

        // Nearest preceding, else nearest following.
        let preceding = pool.filter { $0.id < sliced.id }.max(by: { $0.id < $1.id })
        return preceding ?? pool.min(by: { $0.id < $1.id })
    }
}

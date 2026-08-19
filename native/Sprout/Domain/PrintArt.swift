import Foundation

/// Which library file the machine is currently printing.
///
/// The printer reports a job by NAME (`subtaskName`) and nothing else — no library id, no hash. So
/// the only way to put the print's own picture on a Live Activity card is to find the row whose name
/// matches, and the matching has to survive the three ways the same job is spelled:
///
///  - the printer drops the extension: `planter-lattice` for `planter-lattice.gcode.3mf`
///  - the library stores the slicer's output name: `planter-lattice.gcode.3mf`
///  - uploads arrive percent-encoded: `Adapter%20hexagon.stl`
///
/// Pure and separate from the fetching, because this is the half that is wrong in ways nobody
/// notices: a mismatch shows the WRONG MODEL on the lock screen, which is worse than showing none —
/// the fallback ladder degrades to a brand glyph, and a glyph is honest.
enum PrintArt {

    /// Extensions the printer strips, longest first so `.gcode.3mf` is not read as `.3mf` with a
    /// leftover `.gcode`.
    private static let extensions = [".gcode.3mf", ".gcode", ".3mf", ".stl", ".obj", ".ply"]

    /// A name reduced to what both sides agree on: decoded, lowercased, extension removed.
    static func stem(_ raw: String) -> String {
        var name = (raw.removingPercentEncoding ?? raw).lowercased()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in extensions where name.hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }
        return name
    }

    /// The library row for the job the printer says it is running, or nil.
    ///
    /// **Only ever an exact stem match.** A fuzzy or prefix match is tempting — the names nearly
    /// always agree — but "nearly" is doing the work there, and the failure is silent and wrong: a
    /// library holding `benchy` and `benchy v2` would put one model's render on the other's card and
    /// nothing would ever report it. Nil is a fine answer; the card falls back to the brand glyph.
    ///
    /// Ties are broken by the HIGHEST id, i.e. the most recently added. Re-uploading a file is the
    /// ordinary way a name repeats, and the newest is the one just printed.
    static func match(jobName: String, in library: [LibraryFile]) -> LibraryFile? {
        let wanted = stem(jobName)
        guard !wanted.isEmpty else { return nil }
        let matches = library.filter { file in
            guard file.thumbnailPath != nil else { return false }
            if stem(file.filename) == wanted { return true }
            if let printName = file.printName, !printName.isEmpty, stem(printName) == wanted { return true }
            return false
        }
        return matches.max(by: { $0.id < $1.id })
    }

    /// The file whose THUMBNAIL should be shown for a job — the match, or the model it was sliced
    /// from when the match's own image is Bambuddy's flat silhouette.
    ///
    /// Reuses `ThumbSource` rather than re-deriving the sliced/source link, so the Live Activity and
    /// the Files grid cannot disagree about which picture represents a print.
    static func artFile(jobName: String, in library: [LibraryFile]) -> LibraryFile? {
        guard let matched = match(jobName: jobName, in: library) else { return nil }
        return ThumbSource.sourceCandidate(for: matched, in: library) ?? matched
    }
}

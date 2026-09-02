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

    /// Which PLATE of a multi-plate file is printing, or nil when nothing says.
    ///
    /// A `.gcode.3mf` holds one gcode per plate, and the printer runs exactly one of them. The plate
    /// render endpoint is indexed, and its index DEFAULTS TO 1 — so a job sent from Handy as plate 2
    /// or 3 put plate 1's picture on the card, which is the "wrong model on the lock screen" failure
    /// this file exists to prevent, arriving through the index instead of through the name.
    ///
    /// `gcodeFile` is preferred because it is the file the machine is EXECUTING — the strongest
    /// evidence of which plate is running. `currentPlateId` is a reported field and only a fallback:
    /// this printer already reports `active_extruder` wrongly, so a second opinion is worth having
    /// and worth ranking below the artefact itself.
    ///
    /// nil, not 1, when neither says. "Plate 1" and "no idea which plate" are different answers, and
    /// conflating them is exactly how the default got here.
    static func plateIndex(gcodeFile: String?, currentPlateId: Int? = nil) -> Int? {
        if let n = plateNumber(inPath: gcodeFile) { return n }
        if let id = currentPlateId, id > 0 { return id }
        return nil
    }

    /// `/data/Metadata/plate_3.gcode` → 3. Searches BACKWARDS: a user's own folder may contain
    /// `plate_2` in its name, and the segment that decides is the last one.
    static func plateNumber(inPath path: String?) -> Int? {
        guard let path, let marker = path.range(of: "plate_", options: .backwards) else { return nil }
        let digits = path[marker.upperBound...].prefix { $0.isNumber }
        guard let n = Int(digits), n > 0 else { return nil }
        return n
    }

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

    /// The entry on the printer's own storage that matches the running job, if any.
    ///
    /// **This is the rung that actually fires for most prints, and it was missing.** Measured against
    /// the live machine: the running job was `kid34_slide_A_76`, the library held nine rows with
    /// thumbnails and NONE of them matched, and the printer's own card held
    /// `/kid34_slide_A_76.gcode.3mf` whose plate render returns 200. A library-only ladder shows the
    /// brand glyph for every print that was not started from the library — which for a machine driven
    /// from Bambu Studio or its own screen is most of them.
    ///
    /// Same exact-stem rule as `match`, and for the same reason: a near-match puts the wrong model on
    /// the lock screen, which is worse than the honest glyph.
    static func matchSd(jobName: String, in files: [PrinterFile]) -> PrinterFile? {
        let wanted = stem(jobName)
        guard !wanted.isEmpty else { return nil }
        return files.first { !$0.isDirectory && stem($0.name) == wanted }
    }

    /// Whether the printer's card is worth listing (again) for this job.
    ///
    /// The listing is cached for the whole launch, because the card is searched on a 4-second loop
    /// and re-listing 70 files every tick to find one picture is absurd. But a cache keyed only by
    /// PRINTER answers "have we asked this machine?" when the question is "could what we hold
    /// contain the job that is running now?" — and those come apart exactly in the case this rung
    /// exists for. Send a print from Bambu Studio or Handy and the file reaches the card AFTER the
    /// app cached its listing, so the job is missing from the copy we hold, is never looked for
    /// again, and the card shows the brand glyph for the entire session. Restarting the app fixed
    /// it, which is the tell.
    ///
    /// So the memo is keyed by JOB. A listing that already contains the job is used as-is; a
    /// listing that does not earns exactly one re-list per job name, after which the answer stands
    /// until the printer starts something else. Bounded at one request per job per launch, which is
    /// what the caching was protecting in the first place.
    static func shouldListCard(job: String, browsed: [PrinterFile], cached: [PrinterFile]?,
                               alreadyAsked: Bool) -> Bool {
        if matchSd(jobName: job, in: browsed) != nil { return false }
        if let cached, matchSd(jobName: job, in: cached) != nil { return false }
        return !alreadyAsked
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

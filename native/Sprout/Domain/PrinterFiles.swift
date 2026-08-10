import Foundation

/// Pure helpers for the printer's SD-card browser: which files are openable, which folders hold
/// recordings, and the naming conventions the printer itself uses for posters and timestamps.
enum PrinterFiles {

    /// Sliced Bambu print files (`.gcode.3mf` / `.3mf`) — these get a plate preview and the layer
    /// viewer. Requires the dot, so `notes.3mf.txt` is not one.
    /// A sliced 3MF — one that actually carries toolpaths and plate metadata.
    ///
    /// `.gcode.3mf`, NOT any `.3mf`: a plain project 3MF has no G-code, and treating it as sliced
    /// offers a layer view whose request 404s.
    static func isSliced3mf(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".gcode.3mf")
    }

    /// AVPlayer plays the printer's timelapse `.mp4`s; `.avi` (older firmwares) is NOT playable.
    static func isPlayableVideo(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".mp4")
    }

    /// The printer's video folders — `/timelapse` (finished-print timelapses) and `/ipcam` (raw
    /// camera recordings, ~250 MB 10-minute chunks). Both use the same layout and render as a
    /// thumbnail grid. Top level only: `/timelapse/thumbnail` holds posters, not videos.
    ///
    /// `lowercased()` is the locale-INDEPENDENT one on purpose. A locale-sensitive lowercase would
    /// fold "IPCAM" to "ıpcam" (dotless i) under a Turkish locale and the folder would stop matching
    /// on those devices.
    static func isMediaFolder(_ path: String) -> Bool {
        let lower = path.lowercased()
        let withoutTrailingSlash = lower.hasSuffix("/") ? String(lower.dropLast()) : lower
        return withoutTrailingSlash == "/timelapse" || withoutTrailingSlash == "/ipcam"
    }

    /// The printer stores a poster JPEG per video with the SAME basename in a `thumbnail`
    /// subfolder:
    ///
    ///     /timelapse/video_x.mp4        -> /timelapse/thumbnail/video_x.jpg
    ///     /ipcam/ipcam-record.<d>.0.mp4 -> /ipcam/thumbnail/ipcam-record.<d>.0.jpg
    ///
    /// (both verified on the live H2C SD card). ipcam basenames contain DOTS, so only the final
    /// extension may be swapped — splitting on the first dot would ask for a file that isn't there.
    ///
    /// A path with no directory or no extension is returned unchanged rather than turned into a
    /// half-built URL that would 404.
    static func mediaThumbPath(_ videoPath: String) -> String {
        guard let slash = videoPath.lastIndex(of: "/") else { return videoPath }
        let directory = videoPath[videoPath.startIndex..<slash]
        let file = videoPath[videoPath.index(after: slash)...]
        // The dot must have a basename before it and an extension after it.
        guard let dot = file.lastIndex(of: "."), dot > file.startIndex else { return videoPath }
        let ext = file[file.index(after: dot)...]
        guard !ext.isEmpty else { return videoPath }
        return "\(directory)/thumbnail/\(file[file.startIndex..<dot]).jpg"
    }

    /// `video_2026-07-05_15-16-02.mp4` / `ipcam-record.2026-07-05_15-16-02.3.mp4` -> `Jul 5, 15:16`,
    /// falling back to the raw name when there is no timestamp to read.
    static func mediaLabel(_ name: String) -> String {
        let chars = Array(name)
        guard chars.count >= stampLength else { return name }
        for start in 0...(chars.count - stampLength) where isStamp(chars, at: start) {
            let month = twoDigitValue(chars, at: start + 5)
            // A structurally valid stamp with a nonsense month (…-99-…) is not a date: keep the raw
            // filename instead of inventing a month, and stop — the printer writes at most one
            // stamp per name, so a later match would be coincidence, not a better reading.
            guard month >= 1, month <= months.count else { return name }
            let day = twoDigitValue(chars, at: start + 8)
            // Hour and minute are copied verbatim so they keep their leading zero ("09:05"); the day
            // is parsed to a number so it loses one ("Jul 5", not "Jul 05").
            let hour = String(chars[(start + 11)...(start + 12)])
            let minute = String(chars[(start + 14)...(start + 15)])
            return "\(months[month - 1]) \(day), \(hour):\(minute)"
        }
        return name
    }

    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Characters in `YYYY-MM-DD_HH-MM`.
    private static let stampLength = 16

    /// Whether a `YYYY-MM-DD_HH-MM` stamp starts at `index`. The caller guarantees the 16 characters
    /// are in bounds.
    private static func isStamp(_ chars: [Character], at index: Int) -> Bool {
        // ASCII only: a filename carrying Arabic-Indic digits is not a stamp this printer wrote.
        func digits(_ range: Range<Int>) -> Bool {
            range.allSatisfy { chars[$0].isASCII && chars[$0].isNumber }
        }
        return digits(index..<(index + 4)) && chars[index + 4] == "-"
            && digits((index + 5)..<(index + 7)) && chars[index + 7] == "-"
            && digits((index + 8)..<(index + 10)) && chars[index + 10] == "_"
            && digits((index + 11)..<(index + 13)) && chars[index + 13] == "-"
            && digits((index + 14)..<(index + 16))
    }

    /// Value of the two ASCII digits at `index`.
    private static func twoDigitValue(_ chars: [Character], at index: Int) -> Int {
        Int(String(chars[index...(index + 1)])) ?? 0
    }
}

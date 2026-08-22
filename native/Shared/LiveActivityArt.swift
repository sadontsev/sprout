import Foundation

/// Where a Live Activity's images live, and the rules for naming them.
///
/// **A widget is a separate process.** It cannot read the app's sandbox, cannot use its `URLCache`,
/// and cannot be handed a `UIImage` — the only thing that crosses is the content state, which is
/// JSON. So an image reaches the card exactly one way: the app writes a file into the shared App
/// Group container and puts its `file://` URI in the state.
///
/// **The container was declared and never used.** `group.com.mvks5.bambu` has been in all three
/// entitlements files since the widget was written, and no code ever called `containerURL`. So
/// `modelUri` and `iconUri` were always empty, the card's three-step fallback ladder always fell to
/// step three, and every Live Activity ever shown by this app displayed a generic SF Symbol where the
/// print was meant to be. That is the gap this type closes.
///
/// The path rules are pure and separated from the writing, because the writing needs a real container
/// and a real image encoder while the rules are what actually go wrong: two printers overwriting one
/// another's plate, or a stale file from last week's print being shown for today's.
enum LiveActivityArt {

    /// Must equal the `com.apple.security.application-groups` entry in all three entitlements files.
    static let groupId = "group.com.mvks5.bambu"

    /// Everything this type writes goes in one subdirectory, so a future "clear the art" is a single
    /// `removeItem` rather than a pattern match over the container's root — which the push code also
    /// writes to.
    static let directoryName = "live-activity"

    /// The brand nozzle, written once. Shared by the leading-slot fallback and the extrusion bar's
    /// rider, so one file serves both and neither can get a different vintage of the artwork.
    static let glyphName = "nozzle.png"

    /// What a plate file CONTAINS, as opposed to which job it is for. Bump it whenever the bytes
    /// written for the same job would now differ.
    ///
    /// Without this the name is a stable address over changing content — the same defect that hid a
    /// repainted thumbnail behind its own URL, one layer down. `plate()` returns an existing file
    /// untouched, by design, so a plate written before `PlateGround` existed stays ungrounded for
    /// the life of that print no matter how many builds land. Bumping the version makes the new rule
    /// look for a name nothing has written yet, and `sweepPlates` collects the old one because it
    /// still matches the `plate-` prefix.
    ///
    /// 2 — a transparent cover is composited onto a contrasting ground (`PlateGround`).
    static let plateFormat = 2

    /// **Per printer, and per FILE.** Two printers running produce two cards; naming the plate by
    /// printer alone means the second card's write overwrites the first card's image and both then
    /// show the same model. Including a hash of the file name also makes a new job's write land on a
    /// new path, so a card cannot show the previous print's plate while the new thumbnail downloads.
    static func plateName(printerId: Int, fileName: String) -> String {
        "plate-\(printerId)-\(stableHash(fileName))-v\(plateFormat).png"
    }

    /// A stable, filesystem-safe digest of the file name.
    ///
    /// Deliberately NOT `hashValue`: Swift seeds string hashing per process, so the app and the
    /// widget would compute different names for the same file, and the app would produce a different
    /// one on every launch — the card would flicker between a fresh write and a missing file. FNV-1a
    /// is stable, tiny, and this is a cache key rather than a security boundary.
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x1000_0000_01b3
        }
        return String(h, radix: 36)
    }

    // MARK: - The container

    /// The directory, created on demand. `nil` when the App Group is unavailable — which is a real
    /// case, not a defensive one: a build signed by a team that does not own this group gets no
    /// container, and CLAUDE.md records that such builds are a supported configuration.
    static func directory(fileManager: FileManager = .default) -> URL? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
            return nil
        }
        let dir = container.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Write `data` under `name`, returning the URI to put in the content state.
    ///
    /// Returns "" rather than nil on failure, because that is what the content state's fallback
    /// ladder is written against — an empty string means "try the next rung", and a card with a
    /// generic symbol is a far better outcome than one that fails to render.
    @discardableResult
    static func write(_ data: Data, name: String, fileManager: FileManager = .default) -> String {
        guard let dir = directory(fileManager: fileManager) else { return "" }
        let url = dir.appendingPathComponent(name)
        // Skip an identical rewrite: `sync` runs on every status frame, and rewriting the same
        // bytes every few seconds would churn the container and invalidate the widget's read for no
        // reason.
        if let existing = try? Data(contentsOf: url), existing == data {
            return url.absoluteString
        }
        do {
            try data.write(to: url, options: .atomic)
            return url.absoluteString
        } catch {
            return ""
        }
    }

    /// The URI for a file already written, or "" — used to fill the content state without re-writing
    /// on every status frame.
    static func existingURI(name: String, fileManager: FileManager = .default) -> String {
        guard let dir = directory(fileManager: fileManager) else { return "" }
        let url = dir.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url.absoluteString : ""
    }

    /// The plate image for a card — whether or not the push that delivered it carried one.
    ///
    /// **A remote update REPLACES the whole `ContentState`.** Trellis has no idea which plate the
    /// device wrote, so `classify()` sends `modelUri: ""` on every push, and the first server update
    /// after the app resolved a plate blanked the preview — seconds after it appeared — leaving the
    /// brand glyph for the rest of the print. `iconUri` survived only because it is registered per
    /// push token and echoed back; a plate is per JOB and there is nothing to echo.
    ///
    /// The device does not need to be told. `plateName` is pure, `printerId` is a static ATTRIBUTE
    /// that no push can touch, and `name` is the same `subtask_name` the app matched the plate on —
    /// so the widget can derive the path itself and treat a carried `modelUri` as a shortcut rather
    /// than the source of truth.
    ///
    /// Fixing it here rather than in Trellis is deliberate: `ContentState`'s field names are a wire
    /// format shared with a service that deploys separately, and this needs no new field, no new
    /// endpoint and no version skew. It also holds for a user whose Trellis is older than their app.
    static func plateURI(printerId: Int, jobName: String, carried: String,
                         fileManager: FileManager = .default) -> String {
        if !carried.isEmpty { return carried }
        guard !jobName.isEmpty else { return "" }
        return existingURI(name: plateName(printerId: printerId, fileName: jobName),
                           fileManager: fileManager)
    }

    /// Remove plate images that no live card refers to.
    ///
    /// Without this the container grows by one PNG per distinct file name ever printed, forever —
    /// invisible to the user, counted against the app's storage, and never cleaned by anything else.
    /// The glyph is deliberately never swept: it is one file and every card needs it.
    static func sweepPlates(keeping keep: Set<String>, fileManager: FileManager = .default) {
        guard let dir = directory(fileManager: fileManager),
              let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("plate-") && !keep.contains(name) {
            try? fileManager.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

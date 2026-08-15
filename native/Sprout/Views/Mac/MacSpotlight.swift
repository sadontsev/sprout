#if os(macOS)
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os

private let spotlightLog = Logger(subsystem: "com.mvks5.bambu", category: "spotlight")

/// Indexes the library into Spotlight (§5.4).
///
/// Opening a hit launches Sprout with `bambu://file/<id>`, which `MacOpenRouter` turns into a
/// selection in Files. That URL scheme is already declared, so this is the other half of a road
/// that was already half built.
///
/// **De-indexing is not optional, and is the whole reason this is a diff rather than a re-index.**
/// A hit that opens a file the server no longer has is worse than no hit at all: Spotlight is
/// trusted, so the failure reads as the app losing the file rather than as a stale index. The
/// indexer therefore tracks the ids it has published and removes the difference on every pass.
///
/// It is also incremental because it is called on every library refresh — which is every 30 s while
/// Files is on screen. Re-indexing several hundred items at that cadence would keep `mdworker`
/// permanently busy for no benefit; the overwhelmingly common pass has nothing to do at all.
@MainActor
final class MacSpotlightIndexer {
    static let shared = MacSpotlightIndexer()

    /// The domain everything is filed under, so `deleteSearchableItems(withDomainIdentifiers:)` can
    /// clear the lot on sign-out without touching anything else the user has indexed.
    static let domain = "com.mvks5.bambu.library"

    /// What is currently published, and the fingerprint it was published with. The fingerprint is
    /// what makes this a diff: a file whose name, size and print time are unchanged does not need
    /// re-indexing, and re-indexing it would be the whole cost of the pass.
    private var published: [Int: Int] = [:]

    private let index = CSSearchableIndex.default()

    /// Reconcile the index against the library as it now is.
    func sync(_ files: [LibraryFile]) {
        var wanted: [Int: Int] = [:]
        var changed: [CSSearchableItem] = []

        for file in files {
            let print = fingerprint(file)
            wanted[file.id] = print
            if published[file.id] != print {
                changed.append(item(for: file))
            }
        }

        let removed = published.keys.filter { wanted[$0] == nil }
        published = wanted

        if !changed.isEmpty {
            index.indexSearchableItems(changed) { error in
                if let error { spotlightLog.error("index failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        if !removed.isEmpty {
            index.deleteSearchableItems(withIdentifiers: removed.map(Self.identifier)) { error in
                if let error { spotlightLog.error("de-index failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    /// Drop everything on sign-out. The library belonged to a server this Mac is no longer talking
    /// to, and leaving it searchable would offer files the app can no longer open.
    func clear() {
        published = [:]
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { error in
            if let error { spotlightLog.error("clear failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    static func identifier(_ id: Int) -> String { "bambu.file.\(id)" }

    /// Everything a hit's display and freshness depend on. Deliberately NOT the whole record: a
    /// field Spotlight never shows changing should not cost a re-index.
    private func fingerprint(_ f: LibraryFile) -> Int {
        var hasher = Hasher()
        hasher.combine(f.filename)
        hasher.combine(f.printName)
        hasher.combine(f.fileType)
        hasher.combine(f.fileSize?.value)
        hasher.combine(f.printTimeSeconds?.value)
        hasher.combine(f.filamentUsedGrams?.value)
        return hasher.finalize()
    }

    private func item(for f: LibraryFile) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .data)
        attrs.title = LibraryBrowse.displayName(f)
        attrs.displayName = LibraryBrowse.displayName(f)
        // The searchable text. `filename` is included separately from the display name because a
        // sliced file's display name drops the extension, and "gcode" is a thing people search for.
        attrs.keywords = [f.filename, f.fileType].compactMap { $0 }
        attrs.contentDescription = description(f)
        attrs.contentType = UTType.data.identifier
        if let size = f.fileSize?.value { attrs.fileSize = NSNumber(value: size) }
        return CSSearchableItem(
            uniqueIdentifier: Self.identifier(f.id),
            domainIdentifier: Self.domain,
            attributeSet: attrs
        )
    }

    /// The subtitle Spotlight shows. Only states what is actually recorded — an unsliced model has
    /// no print time, and "0m" would be a claim rather than a blank.
    private func description(_ f: LibraryFile) -> String {
        var parts: [String] = []
        if let type = f.fileType { parts.append(type.uppercased()) }
        if let seconds = f.printTimeSeconds?.value, seconds > 0 {
            parts.append(Dash.fmtDuration(seconds / 60))
        }
        if let grams = f.filamentUsedGrams?.value, grams > 0 {
            parts.append("\(Int(grams.rounded())) g")
        }
        return parts.joined(separator: " · ")
    }
}
#endif

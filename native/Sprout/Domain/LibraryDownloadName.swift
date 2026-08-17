import Foundation

// Extracted from LibraryView. It sanitises a filename into a URL path segment — no view, no
// platform, and the macOS Files section builds the same download URLs.

/// Reduces a name to something that can be **one path segment** of a download URL.
///
/// `GET /api/v1/library/files/{id}/dl/{token}/{filename}` does not care what the filename says — an
/// invented one still answers 200 — but it is a single path segment, and the server percent-DECODES
/// the path before it routes. A name carrying a separator therefore becomes an EXTRA segment and the
/// route stops matching, which is HTTP **404** from an endpoint that answers 403 for every bad
/// credential and 200 for every filename it recognises as one. Names reach here from
/// `print_name` — free-form server text, e.g. a MakerWorld title like `Bracket 20/40` — and from
/// `filename` after a `removingPercentEncoding` round trip that can turn `%2F` back into `/`.
///
/// `.` and `..` are the same failure by a different route: URL resolution folds them away and the
/// path loses a segment. An empty name leaves a trailing slash with no segment at all.
enum LibraryDownloadName {
    static func pathSegment(_ name: String, fallback: String) -> String {
        sanitised(name, fallback: fallback, alsoReplacing: [])
    }

    /// Reduces a name to something safe to write into the caches directory as **one file**.
    ///
    /// The same rule as `pathSegment` plus `:`, because the two questions differ by exactly that
    /// character: a colon is legal in a URL path segment and is the classic HFS separator, so a name
    /// like `Bracket 20:40` is fine in a URL and a hazard in a filename.
    ///
    /// This exists because the rule had been written **three** times — here, as
    /// `MacFileBrowse.safeShareName`, and privately as `LibraryBrowse.safeShareName` inside the
    /// iOS-only view — and a share that downloads an SD file needed a fourth. `MacFileBrowse` now
    /// delegates here. The iOS copy still stands and should follow when that file is next opened; it is
    /// `private` inside `#if os(iOS)`, so it cannot be reached from this side to be deleted.
    static func fileName(_ name: String, fallback: String) -> String {
        sanitised(name, fallback: fallback, alsoReplacing: [":"])
    }

    /// The shared walk. Runs of separators **collapse** to a single `-`, which is what the regex-based
    /// `safeShareName` has always done — kept deliberately so adopting this rule changes no existing
    /// cache filename. `pathSegment` gains that collapsing, which only ever shortens a name it was
    /// already rewriting.
    private static func sanitised(
        _ name: String,
        fallback: String,
        alsoReplacing extra: Set<Unicode.Scalar>
    ) -> String {
        var cleaned = ""
        var lastWasSeparator = false
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == "\\" || extra.contains(scalar) {
                if !lastWasSeparator { cleaned.unicodeScalars.append("-") }
                lastWasSeparator = true
            } else if scalar.value >= 0x20, scalar.value != 0x7F {
                // Control characters can only survive as percent-escaped noise; drop them.
                cleaned.unicodeScalars.append(scalar)
                lastWasSeparator = false
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? fallback : trimmed
    }
}

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
        var cleaned = ""
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == "\\" {
                cleaned.unicodeScalars.append("-")
            } else if scalar.value >= 0x20, scalar.value != 0x7F {
                // Control characters can only survive as percent-escaped noise; drop them.
                cleaned.unicodeScalars.append(scalar)
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? fallback : trimmed
    }
}

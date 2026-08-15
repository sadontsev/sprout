import Foundation

/// The type chips above the list. Counts are computed against the UNFILTERED list, so they never
/// move as the user types.
enum LibraryTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case models
    case sliced

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .models: "Models"
        case .sliced: "Sliced"
        }
    }
}

/// Filter / search / naming rules for the library list. Pure, so no view re-derives them.
///
/// The "can this file do X" questions live in `LibraryFileCaps` instead — the wizard asks them too,
/// and a second copy of `hasGcode` is exactly how it stopped agreeing with `isSliced`.
///
/// Lives in `Domain/` because BOTH view trees need it. It was `private` inside the iOS-only
/// `LibraryView.swift`, so the macOS Files section could not see it and grew its own copies of
/// `displayName`, `safeShareName`, `filter` and `sortPrinterFiles` — the exact duplication this
/// port exists to avoid, and worse than it looks: `displayName` feeds
/// `LibraryDownloadName.pathSegment`, which builds the download URL's last path segment. Two copies
/// drifting is not a cosmetic difference between two lists, it is a 404 on one platform.
enum LibraryBrowse {
    /// Upload names arrive percent-encoded (`Adapter%20hexagon.stl`). A malformed escape decodes to
    /// nil, in which case the raw name is still better than nothing.
    static func displayName(_ f: LibraryFile) -> String {
        let raw = [f.printName, f.filename].compactMap { $0 }.first { !$0.isEmpty } ?? "file-\(f.id)"
        return raw.removingPercentEncoding ?? raw
    }

    /// Display names are user-derived and may contain path separators that a cache filename would
    /// misread as directories.
    static func safeShareName(_ name: String) -> String {
        let n = name
            .replacingOccurrences(of: "[/\\\\:]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "file" : n
    }

    /// The query matches BOTH the decoded display name and the raw filename, so "hexagon" finds
    /// `Adapter%20hexagon.stl` whichever form the user has in mind.
    static func filter(_ files: [LibraryFile], _ filter: LibraryTypeFilter, _ query: String) -> [LibraryFile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return files.filter { f in
            let sliced = LibraryFileCaps.isSliced(f)
            if filter == .sliced, !sliced { return false }
            if filter == .models, sliced { return false }
            if q.isEmpty { return true }
            return displayName(f).lowercased().contains(q) || (f.filename).lowercased().contains(q)
        }
    }

    /// Directories first, then locale name order.
    static func sortPrinterFiles(_ files: [PrinterFile]) -> [PrinterFile] {
        files.sorted { a, b in
            a.isDirectory == b.isDirectory
                ? a.name.localizedCompare(b.name) == .orderedAscending
                : a.isDirectory
        }
    }

    /// The containing folder of an SD path, always with a leading slash. `/` is its own parent.
    static func parentPath(_ path: String) -> String {
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/") else { return "/" }
        let parent = String(p[p.startIndex..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

enum LibraryFormat {
    /// Decimal MB/KB, matching the server's own accounting. Zero and nil both render as nothing —
    /// an unknown size should take up no space rather than claim "0 B".
    static func bytes(_ n: Double?) -> String {
        guard let n, n != 0, n.isFinite else { return "" }
        if n > 1e6 { return String(format: "%.1f MB", n / 1e6) }
        if n > 1e3 { return String(format: "%.0f KB", n / 1e3) }
        return "\(Int(n)) B"
    }
}

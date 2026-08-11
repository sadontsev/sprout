import Foundation

/// Turning MakerWorld search hits into something a grid can render, and deciding what a typed string
/// means.
///
/// Pure, because the interesting parts are judgement calls about **what may honestly be claimed from
/// a hit**, and those are worth pinning: a hit is a thin projection, several of the fields the design
/// assumed are simply absent, and rendering a claim from an absent field is how this codebase has
/// shipped its recurring bug five times.
enum MakerWorldSearch {

    // MARK: What the user typed

    /// What a single input field should do with what is in it.
    ///
    /// One field rather than two. The paste-a-link path must stay first-class permanently — search is
    /// an undocumented endpoint that may be gated at any time, and the day it is, this feature is
    /// removed rather than worked around. Making the link path a *mode of the same field* means it
    /// cannot rot into a fallback nobody maintains.
    ///
    /// The test is exact, not a proxy: a MakerWorld model URL is `/models/<digits>`. Anything else is
    /// a search term, including a URL to some other site — the user gets a search for it and can see
    /// that is what happened, rather than a "that isn't a MakerWorld link" refusal for a string they
    /// never claimed was one.
    enum Intent: Equatable, Sendable {
        case idle
        case resolve(modelId: Int)
        case search(String)

        var buttonLabel: String {
            switch self {
            case .idle, .search: return "Search"
            case .resolve: return "Open"
            }
        }
    }

    static func intent(for raw: String) -> Intent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .idle }
        if let match = trimmed.firstMatch(of: /makerworld\.com\/.*models\/(\d+)/),
           let id = Int(match.1) {
            return .resolve(modelId: id)
        }
        // A bare model id is a link too — it is what the API speaks, and pasting one is a natural
        // thing to try.
        if trimmed.allSatisfy(\.isNumber), trimmed.count >= 4, let id = Int(trimmed) {
            return .resolve(modelId: id)
        }
        return .search(trimmed)
    }

    /// The canonical URL for a hit, which is what `POST /makerworld/resolve` takes. Search adds an
    /// entry point, not a second flow.
    static func modelUrl(id: Int) -> String { "https://makerworld.com/models/\(id)" }

    // MARK: What a tile may claim

    /// The one-line stat under a tile, built only from counts the hit actually carries.
    ///
    /// Zero is a real answer and is shown; **absent is not zero** and is omitted. A brand-new model
    /// with `downloadCount: 0` says "0 downloads"; one where the field is missing says nothing about
    /// downloads at all.
    static func stats(_ hit: MWSearchHit) -> String {
        var parts: [String] = []
        if let d = hit.downloadCount { parts.append("\(compact(d)) download\(d == 1 ? "" : "s")") }
        if let p = hit.printCount, p > 0 { parts.append("\(compact(p)) print\(p == 1 ? "" : "s")") }
        if parts.isEmpty, let l = hit.likeCount { parts.append("\(compact(l)) like\(l == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }

    /// `12`, `1.2k`, `48k`, `1.3M`. Download counts on MakerWorld reach seven figures and a raw
    /// integer wraps the tile.
    static func compact(_ n: Int) -> String {
        let v = abs(n)
        switch v {
        case 0..<1_000: return "\(n)"
        case 1_000..<10_000: return trim(Double(n) / 1_000, "k")
        case 10_000..<1_000_000: return "\(n / 1_000)k"
        case 1_000_000..<10_000_000: return trim(Double(n) / 1_000_000, "M")
        default: return "\(n / 1_000_000)M"
        }
    }

    private static func trim(_ v: Double, _ suffix: String) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))\(suffix)" : String(format: "%.1f%@", r, suffix)
    }

    /// The licence chip for a tile, or `nil`. Reuses the detail screen's rules so a model does not
    /// change licence label between the grid and the sheet.
    static func licence(_ hit: MWSearchHit) -> MWLicence? {
        hit.license?.nonEmpty.map { MWLicence(code: $0) }
    }

    /// Whether to mark a hit as adult content.
    ///
    /// Marked, not hidden: silently dropping hits would contradict the result count the same response
    /// reports, and a single-user app has nobody to protect the user from but themselves.
    static func isAdult(_ hit: MWSearchHit) -> Bool { hit.nsfw == true }

    /// Deliberately absent: any "not printable" marker.
    ///
    /// `isPrintable` was measured **absent** from live hits, so `false` and "not stated" are the same
    /// value. Rendering a negative claim from a missing field is the recurring bug in its purest
    /// form — the answer to "did MakerWorld say this is unprintable" is "MakerWorld said nothing".

    // MARK: Sorting

    /// How to order the results already on screen.
    ///
    /// **Client-side, and it has to be.** MakerWorld's own search API does not sort: `orderBy`,
    /// `order`, `sortBy`, `sortType` and friends were each probed against
    /// `search-service/search/design` and the returned `likeCount`/`downloadCount` sequences came
    /// back unordered for every value — and a nonsense value shuffled the list exactly as much as a
    /// real one, which is the endpoint's unstable ordering rather than sorting. The route that DOES
    /// honour `orderBy` is the website's own Next.js data endpoint, which sits behind a Cloudflare
    /// challenge and needs a browser's `cf_clearance` cookie, so the app cannot reach it.
    ///
    /// So this reorders **what has been loaded**, and the UI says so. A chip labelled "Most
    /// downloaded" that silently meant "most downloaded of the 20 on screen" would be the recurring
    /// bug; saying it out loud makes it a useful tool instead.
    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case relevance, downloads, likes, newest

        var id: String { rawValue }

        /// **Not "Relevance".** That label claims the endpoint ranked these, and it did not: a search
        /// for "spool" returns 2, 4, 3, 17, 5, 46 downloads in that order out of 10 000 results, and
        /// identical calls seconds apart come back in different orders. Naming it after the machine
        /// that produced it is the only honest option — the website's ranked results come from a
        /// different, Cloudflare-gated route this app cannot reach.
        var label: String {
            switch self {
            case .relevance: return "MakerWorld's order"
            case .downloads: return "Most downloaded"
            case .likes:     return "Most liked"
            case .newest:    return "Newest"
            }
        }

        /// Whether this is the server's own order rather than a local reordering.
        var isServerOrder: Bool { self == .relevance }

        /// Sorting an arbitrary 20 of 10 000 by downloads gives "the most downloaded of a random
        /// 20", which is not what anyone means by it. These sorts deepen the pool first.
        var wantsDeeperPool: Bool { self != .relevance }
    }

    /// Reorder loaded hits. `.relevance` is identity — MakerWorld's own order, untouched.
    ///
    /// Ties keep their existing relative order (the sort is stable via the index tiebreak), so
    /// switching sorts and back does not reshuffle equal rows under the reader.
    static func sorted(_ hits: [MWSearchHit], by sort: Sort) -> [MWSearchHit] {
        guard sort != .relevance else { return hits }
        let keyed = hits.enumerated()
        switch sort {
        case .relevance:
            return hits
        case .downloads:
            return keyed.sorted { rank($0.element.downloadCount, $0.offset, $1.element.downloadCount, $1.offset) }
                .map(\.element)
        case .likes:
            return keyed.sorted { rank($0.element.likeCount, $0.offset, $1.element.likeCount, $1.offset) }
                .map(\.element)
        case .newest:
            // No date on a hit, so this is by id: MakerWorld's model ids increase over time (40146 is
            // a 2023 Benchy, 3047341 a recent one). An approximation, and named "Newest" rather than
            // "Newest first" because it is ordering, not a timestamp anyone can check.
            return keyed.sorted { rank($0.element.id, $0.offset, $1.element.id, $1.offset) }.map(\.element)
        }
    }

    /// Descending by value, ascending by original position on a tie. A missing count sorts last —
    /// absent is not zero, and it must not outrank a genuine 0.
    private static func rank(_ a: Int?, _ ai: Int, _ b: Int?, _ bi: Int) -> Bool {
        switch (a, b) {
        case let (x?, y?): return x == y ? ai < bi : x > y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return ai < bi
        }
    }

    // MARK: Descriptions

    /// A profile's own blurb, as plain text.
    ///
    /// MakerWorld returns it as HTML (`<p>0.2mm layer, 2 walls, 15% infill</p>`). SwiftUI renders
    /// markup literally, so the tags have to go — and the few entities that actually appear have to
    /// be decoded, or a description reads `Bambu &amp; friends`.
    static func plainText(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        var text = html
        // Block-level tags become breaks so a multi-paragraph blurb does not run together.
        for tag in ["</p>", "<br>", "<br/>", "<br />", "</div>", "</li>"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                              ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        // Collapse the blank lines the tag substitution leaves behind.
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    // MARK: Paging

    /// Whether another page exists, given what has been loaded so far.
    ///
    /// Driven by the reported `total` rather than by "the last page came back full", which is wrong
    /// on an exact multiple of the page size and produces one empty request every time.
    static func hasMore(loaded: Int, total: Int?) -> Bool {
        guard let total, total > 0 else { return false }
        return loaded < total
    }

    /// Merge a page into what is already on screen, dropping ids already present.
    ///
    /// The endpoint's ordering is not stable between calls — the same query returned a different
    /// leading hit seconds apart — so paging by offset genuinely can repeat a model. Without this the
    /// grid shows duplicates and `ForEach` gets duplicate ids, which is undefined behaviour rather
    /// than a cosmetic problem.
    static func merge(_ existing: [MWSearchHit], _ page: [MWSearchHit]) -> [MWSearchHit] {
        var seen = Set(existing.map(\.id))
        var out = existing
        for hit in page where !seen.contains(hit.id) {
            seen.insert(hit.id)
            out.append(hit)
        }
        return out
    }

    // MARK: Browse

    /// The categories worth showing, in MakerWorld's own order.
    ///
    /// `Following` and `For You` are dropped: both are personalised to a signed-in account, and this
    /// app is anonymous by design — they would render as categories that quietly return someone
    /// else's idea of relevance, or nothing at all.
    static func browsable(_ navs: [MWNav]) -> [MWNav] {
        navs.filter { $0.key != "Following" && $0.key != "Foryou" && !$0.key.isEmpty }
    }
}

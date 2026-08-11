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

    // MARK: Which language to show

    /// A description and whether it is MakerWorld's translation rather than the author's own words.
    struct Description: Equatable, Hashable, Sendable {
        var html: String
        /// True when this is `summaryTranslated`. The UI says so — a translation presented as the
        /// author's own writing is a small lie, and machine translation is worth knowing about when
        /// the text contains print settings you are about to rely on.
        var isTranslated: Bool
    }

    /// Prefer MakerWorld's translation, fall back to the original.
    ///
    /// **`summaryTranslated` is an EMPTY STRING when there is no translation, not null** — measured
    /// on live data, where an untranslated model returns `"summaryTranslated": ""` alongside a full
    /// `summary`. Checking only for `nil` therefore selects the empty one and renders a blank
    /// description; that is precisely the "a present-but-empty value is not a value" trap this API
    /// has already sprung once, with `total: 0` meaning "not authenticated".
    ///
    /// Emptiness is judged after markup is stripped, because `<p></p>` and `<figure></figure>` are
    /// present-but-empty in exactly the same way.
    static func description(original: String?, translated: String?) -> Description? {
        if let translated, markdown(fromHTML: translated) != nil {
            return Description(html: translated, isTranslated: true)
        }
        if let original, markdown(fromHTML: original) != nil {
            return Description(html: original, isTranslated: false)
        }
        return nil
    }

    // MARK: Rich descriptions

    /// A MakerWorld description as **Markdown**, so its formatting survives.
    ///
    /// These are real HTML documents — the measured tag set on one model is `h2`, `p`, `strong`,
    /// `i`, `br`, `ol`, `li`, `img`, `figure`, `span`, plus custom `boost*` elements. Flattening all
    /// of that to plain text (which is what shipped first) throws away the headings, the emphasis
    /// and the numbered steps that carry most of the meaning: "**6-cell and 9-cell trays**" and
    /// "6-cell and 9-cell trays" are not the same sentence.
    ///
    /// Markdown rather than `NSAttributedString(html:)` on purpose. That initialiser is WebKit-backed,
    /// must run on the main thread, is slow enough to stutter a scroll, and imports its own fonts and
    /// colours which then fight the app's palette. This is a pure string transform: testable, fast,
    /// and it inherits whatever styling the view applies.
    ///
    /// **Text is escaped, markup is not.** Everything between tags is uploader-supplied, so its
    /// Markdown metacharacters are escaped before emitting — otherwise a description reading
    /// `2 * 3 * 4` silently becomes italic, and `[see here]` becomes a broken link. Only the markup
    /// this function generates is meant to be parsed.
    static func markdown(fromHTML html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }

        var out = ""
        var listStack: [(ordered: Bool, counter: Int)] = []

        /// Nested inline spans being collected. Emphasis has to be buffered rather than streamed,
        /// because its delimiters cannot touch whitespace — see `closeEmphasis`.
        enum Frame {
            case link(href: String?)
            case emphasis(marker: String)
            /// Collected and thrown away — MakerWorld's boost widget renders its own title, which is
            /// a button label rather than anything the uploader wrote.
            case discard
        }
        var frames: [(frame: Frame, text: String)] = []
        var linkHref: String?

        func emit(_ s: String) {
            if frames.isEmpty { out += s } else { frames[frames.count - 1].text += s }
        }

        /// True when a marker is already open somewhere up the stack.
        ///
        /// Markdown cannot nest `**` inside `**`, and MakerWorld nests constantly — an `<h2>`
        /// containing a `<strong>` produced `****Compatible with H2D****`, which renders as literal
        /// asterisks. A nested duplicate contributes its text and no delimiters.
        func alreadyOpen(_ marker: String) -> Bool {
            frames.contains { if case .emphasis(let m) = $0.frame { return m == marker } else { return false } }
        }

        /// Emit `**bold**` with any surrounding whitespace moved OUTSIDE the delimiters.
        ///
        /// This is the bug that shipped visibly: MakerWorld's spans routinely carry a trailing space
        /// (`<strong>Seed Sower : </strong>`), and `**Seed Sower : **` is not emphasis in Markdown —
        /// a delimiter adjacent to whitespace is left as literal text, so the asterisks appeared on
        /// screen. Moving the space out makes it `**Seed Sower :** `, which parses.
        ///
        /// A span that holds only whitespace emits nothing at all, delimiters included. Those exist
        /// (`<i> </i>` between words) and used to produce a stray `* *`.
        func closeEmphasis(_ marker: String, _ text: String) {
            guard !marker.isEmpty else { emit(text); return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Keep the whitespace it stood for, drop the empty emphasis.
                emit(text.isEmpty ? "" : " ")
                return
            }
            let leading = text.prefix { $0.isWhitespace }
            let trailing = text.reversed().prefix { $0.isWhitespace }.reversed()
            emit(String(leading) + marker + trimmed + marker + String(trailing))
        }

        var i = html.startIndex
        while i < html.endIndex {
            guard let open = html[i...].firstIndex(of: "<") else {
                emit(escapeMarkdown(decodeEntities(String(html[i...]))))
                break
            }
            if open > i {
                emit(escapeMarkdown(decodeEntities(String(html[i..<open]))))
            }
            guard let close = html[open...].firstIndex(of: ">") else {
                // An unclosed tag at the end is malformed input, not a crash: drop the remainder.
                break
            }
            let raw = String(html[html.index(after: open)..<close])
            i = html.index(after: close)

            let isEnd = raw.hasPrefix("/")
            let body = isEnd ? String(raw.dropFirst()) : raw
            let name = body.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()

            switch name {
            case "strong", "b", "em", "i", "h1", "h2", "h3", "h4", "h5", "h6":
                let heading = name.count == 2 && name.hasPrefix("h")
                // A heading is bold on its own line: inline-only Markdown does not render `#`, and a
                // literal hash on screen looks like a typo.
                let marker = (heading || name == "strong" || name == "b") ? "**" : "*"
                if isEnd {
                    // Tolerate mismatched tags: close only what is genuinely open.
                    if case .emphasis(let open)? = frames.last?.frame {
                        let text = frames.removeLast().text
                        closeEmphasis(open, text)
                        if heading { emit("\n\n") }
                    }
                } else {
                    if heading { emit("\n") }
                    // Empty marker when the same one is already open: text only, no delimiters.
                    frames.append((.emphasis(marker: alreadyOpen(marker) ? "" : marker), ""))
                }
            case "br":
                emit("\n")
            case "p", "div", "figure", "figcaption", "boostme", "boostcontent":
                if isEnd { emit("\n\n") }
            case "ul", "ol":
                if isEnd {
                    listStack.removeLast(listStack.isEmpty ? 0 : 1)
                    emit("\n")
                } else {
                    listStack.append((ordered: name == "ol", counter: 0))
                    emit("\n")
                }
            case "li":
                if !isEnd {
                    if listStack.isEmpty {
                        emit("\n• ")
                    } else {
                        listStack[listStack.count - 1].counter += 1
                        let item = listStack[listStack.count - 1]
                        emit(item.ordered ? "\n\(item.counter). " : "\n• ")
                    }
                }
                // `</li>` deliberately emits nothing: the next `<li>` (or the closing list tag)
                // supplies the break. Emitting one here too double-spaced every list.
            case "a":
                if isEnd {
                    if case .link(let href)? = frames.last?.frame {
                        let text = frames.removeLast().text
                        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let href, !clean.isEmpty {
                            emit("[\(clean)](\(href))")
                        } else {
                            emit(text)
                        }
                    }
                    linkHref = nil
                } else {
                    frames.append((.link(href: safeHref(body)), ""))
                }
            case "boosttitle":
                // MakerWorld's "boost me" widget renders its own title ("Boost Me" / "为我助力").
                // That is a UI label, not something the uploader wrote about their model, so it is
                // collected and thrown away. `boostcontent` IS their words and is kept.
                if isEnd {
                    if case .discard? = frames.last?.frame { frames.removeLast(); emit("\n") }
                } else {
                    frames.append((.discard, ""))
                }
            case "oembed":
                // An embedded video. It cannot play inside a Text, but dropping it silently loses
                // content the uploader added — so it becomes a link, which is what it is.
                if !isEnd, let href = safeHref(body) ?? safeUrlAttribute(body) {
                    emit("\n[Video](\(href))\n")
                }
            case "img":
                // Dropped rather than rendered. A remote image cannot be inlined in a `Text`, and the
                // gallery already shows this model's photos — a broken image marker in the middle of
                // the prose would be worse than its absence.
                break
            default:
                // Unknown and custom elements (MakerWorld ships `boostme`, `boosttitle`, …) keep
                // their contents and lose their tag.
                break
            }
        }

        // Unclosed inline tags are malformed input MakerWorld does send. Flush their text so the
        // words survive; the formatting they asked for does not, which is the right trade.
        while let frame = frames.popLast() {
            if case .discard = frame.frame { continue }
            if frames.isEmpty { out += frame.text } else { frames[frames.count - 1].text += frame.text }
        }

        // Collapse runs of spaces to one, which is what HTML itself does with whitespace — and what
        // stops `Available in <strong> 6-cell </strong>` producing "Available in  **6-cell**", where
        // the text's own trailing space and the span's leading one both survive. Newlines are left
        // alone: they carry the block structure this converter just built.
        out = out.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)

        // Collapse the runs of blank lines the block tags leave behind.
        let lines = out.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var collapsed: [String] = []
        for line in lines {
            if line.isEmpty, collapsed.last?.isEmpty ?? true { continue }
            collapsed.append(line)
        }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        let text = collapsed.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// `<oembed url="…">` names its target with `url`, not `href`.
    private static func safeUrlAttribute(_ tagBody: String) -> String? {
        guard let m = tagBody.firstMatch(of: /url\s*=\s*["']([^"']+)["']/) else { return nil }
        return safeHref("href=\"\(m.1)\"")
    }

    /// Only `http(s)` links are emitted.
    ///
    /// A description is uploader-supplied, so `javascript:` and `data:` hrefs are exactly the kind of
    /// thing that should never reach a tappable link. Anything else keeps its text and loses its URL.
    private static func safeHref(_ tagBody: String) -> String? {
        guard let m = tagBody.firstMatch(of: /href\s*=\s*["']([^"']+)["']/) else { return nil }
        let href = decodeEntities(String(m.1)).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        // Parentheses would terminate the Markdown link target early.
        return href.contains("(") || href.contains(")") ? nil : href
    }

    /// Escape the characters that would otherwise be read as Markdown in uploader text.
    private static func escapeMarkdown(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "\\" || ch == "*" || ch == "_" || ch == "[" || ch == "]" || ch == "`" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    private static func decodeEntities(_ s: String) -> String {
        var text = s
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                              ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&ndash;", "–"),
                              ("&mdash;", "—"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
                              ("&ldquo;", "“"), ("&rdquo;", "”")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
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

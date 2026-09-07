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
    /// `select/design2` does send `is_printable` — in **snake case**, inside an otherwise camelCase
    /// body, so the plain decoder `MWSearchHit` uses cannot see it and it is nil on every hit. It
    /// stays undecoded rather than being wired up: `false` and "not stated" would then be the same
    /// value, and rendering a negative claim from a field that is nil for two different reasons is
    /// the recurring bug in its purest form.

    // MARK: Sorting

    /// The server's own orders on `search-service/select/design2`.
    ///
    /// Measured 2026-09-07: each value changes the returned row set, verified against the
    /// `downloadCount`/`createTime` sequences, not just the ids. The earlier finding that "no
    /// ordering parameter is honoured" was true of `search/design`, a different endpoint. The raw
    /// value is the wire value so a rename here cannot silently stop sorting.
    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case relevance = "score"
        case trending = "hotScore"
        case newest = "newUploads"
        case downloads = "downloadCount"
        case likes = "likeCount"
        case boosts = "boosts"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .relevance: return "Relevance"
            case .trending:  return "Trending"
            case .newest:    return "Newest"
            case .downloads: return "Most downloaded"
            case .likes:     return "Most liked"
            case .boosts:    return "Most boosted"
            }
        }
    }

    /// `category_400` → 400. The nav key is MakerWorld's; the number is what `categories=` wants.
    static func categoryId(navKey: String?) -> Int? {
        guard let navKey, navKey.hasPrefix("category_") else { return nil }
        return Int(navKey.dropFirst("category_".count))
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
    /// else's idea of relevance, or nothing at all. `LaserCut` is dropped because it needs a
    /// `designType` the probes never settled, and a chip that lists 3D models under a laser heading
    /// would be a lie.
    static func browsable(_ navs: [MWNav]) -> [MWNav] {
        navs.filter { $0.key != "Following" && $0.key != "Foryou" && $0.key != "LaserCut" && !$0.key.isEmpty }
    }
}

/// The filters `select/design2` honours. Parameter names and value shapes are the ones the
/// website's own sort links carry after "Confirm" (measured 2026-09-07); every one was replayed
/// against the API and changed `total`.
struct MWSearchFilters: Equatable, Sendable {
    /// `devModelNames=<code>`. nil = any printer. See `MWPrinterCode`.
    var printerCode: String?
    /// `nozzleDiameters=0.4`. Single-select: the site sends one value and a list was never probed.
    var nozzle: String?
    var colours: Colours = .any
    /// Upper bound in minutes; the lower bound is always 1.
    var maxMinutes: Int?
    /// Upper bound in grams; the lower bound is always 1.
    var maxGrams: Int?
    /// MakerWorld licence codes: `CC0`, `BY`, `BY-SA`, `BY-ND`, `BY-NC`, `BY-NC-SA`, `BY-NC-ND`.
    var licences: Set<String> = []
    var tag: Tag = .any
    var customisable = false

    enum Colours: String, CaseIterable, Sendable { case any, single, multi }
    enum Tag: String, CaseIterable, Sendable { case any, featured, exclusive }

    var queryItems: [(String, String)] {
        var out: [(String, String)] = []
        if let printerCode { out.append(("devModelNames", printerCode)) }
        if let nozzle { out.append(("nozzleDiameters", nozzle)) }
        switch colours {
        case .any: break
        case .single: out.append(("multiColor", "false"))
        case .multi: out.append(("multiColor", "true"))
        }
        if let maxMinutes { out.append(("print_duration", "1,\(maxMinutes)")) }
        if let maxGrams { out.append(("total_weight", "1,\(maxGrams)")) }
        if !licences.isEmpty { out.append(("licenses", licences.sorted().joined(separator: ","))) }
        if tag != .any { out.append(("model_tag", tag.rawValue)) }
        if customisable { out.append(("customizable", "true")) }
        return out
    }

    var activeCount: Int { queryItems.count }
    var isEmpty: Bool { activeCount == 0 }
}

/// One page of MakerWorld models, described rather than fetched. `queryItems` is ordered so a URL
/// built from it is stable, which is what the tests pin.
struct MWSearchRequest: Equatable, Sendable {
    var keyword: String?
    var categoryId: Int?
    var sort: MakerWorldSearch.Sort = .relevance
    var filters = MWSearchFilters()
    var offset = 0
    /// 100 was accepted live; 50 keeps a page under a second on cellular.
    var limit = 50
    /// Echoed from the first page's `searchSessionId` on later pages, as the site does.
    var sessionId: String?

    var queryItems: [(String, String)] {
        var out: [(String, String)] = [("designType", "0")]
        if let keyword, !keyword.isEmpty { out.append(("keyword", keyword)) }
        if let categoryId { out.append(("categories", String(categoryId))) }
        out.append(("orderBy", sort.rawValue))
        out += filters.queryItems
        out.append(("limit", String(limit)))
        out.append(("offset", String(offset)))
        if let sessionId { out.append(("searchSessionId", sessionId)) }
        return out
    }
}

/// Bambuddy model strings → MakerWorld `devModelName` codes, read off
/// `design-service/design/{id}` compatibility lists on 2026-09-07.
enum MWPrinterCode {
    private static let table: [String: String] = [
        "H2C": "O1C2", "H2D": "O1D", "H2D PRO": "O1E", "H2S": "O1S",
        "A1": "N2S", "A1 MINI": "N1", "A1M": "N1",
        "P1S": "C12", "P1P": "C11", "P2S": "N7",
        "X1C": "BL-P001", "X1 CARBON": "BL-P001", "X1": "BL-P002", "X1E": "C13",
        "A2L": "N9", "X2D": "N6",
    ]

    static func code(forModel model: String?) -> String? {
        guard let model else { return nil }
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return table[key]
    }
}

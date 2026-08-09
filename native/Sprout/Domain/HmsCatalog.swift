import Foundation

// Human descriptions for HMS / print-error codes, from Bambu's own public feed.
//
// Bambuddy does NOT carry this text (its HMS response is just code/attr/module/severity/actions), and
// the wiki has no page for every code — the H2C's 0C00-0100-0002-0017 404s. But Bambu publishes the
// same table their own software uses: ~4,900 HMS entries + ~650 print-error entries, keyed by the
// exact codes the printer reports. Fetched once and cached, that turns "HMS 0501-0400-0003-0002" into
// "Threaded rods need lubrication now."
//
// It is fetched rather than bundled: the parsed map is ~535 KB of text that changes independently of
// the app.

/// Bambu's descriptions for the codes a printer can report.
struct HmsCatalog: Codable, Hashable, Sendable {
    /// 16-hex full code (uppercase, separators stripped) -> description.
    var hms: [String: String]
    /// Decimal print_error, as text -> description.
    var err: [String: String]
    /// Descriptions scraped from the wiki for codes the feed doesn't carry (e.g. every H2-family code
    /// — verified: 0C00010000020017 is absent from the feed but documented on the wiki). Persisted, so
    /// a given code costs one request ever.
    var learned: [String: String]
    var fetchedAt: Date

    init(hms: [String: String] = [:], err: [String: String] = [:], learned: [String: String] = [:], fetchedAt: Date = .distantPast) {
        self.hms = hms
        self.err = err
        self.learned = learned
        self.fetchedAt = fetchedAt
    }

    /// Nothing known yet. Alerts still render their code, just without prose.
    static let empty = HmsCatalog()

    enum CodingKeys: String, CodingKey {
        case hms, err, learned, fetchedAt
    }

    /// Every section is optional on the way in. A cache written by an earlier build has no `learned`
    /// map, and a strict decode would throw the whole file away — losing every description that build
    /// had already paid a request to learn.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hms = try c.decodeIfPresent([String: String].self, forKey: .hms) ?? [:]
        err = try c.decodeIfPresent([String: String].self, forKey: .err) ?? [:]
        learned = try c.decodeIfPresent([String: String].self, forKey: .learned) ?? [:]
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }
}

// MARK: - Lookups

extension HmsCatalog {
    /// The map key for a code: separators stripped, upper-cased. The printer, the feed and the wiki
    /// each write the same code differently, so every read and write goes through this.
    static func key(for code: String) -> String {
        code.filter { $0 != "-" && $0 != "_" && !$0.isWhitespace }.uppercased()
    }

    /// Description for a printer-reported HMS code. Accepts the dashed display form, the underscore
    /// form the wiki uses, or raw hex.
    func describeHms(_ code: String?) -> String? {
        guard let code else { return nil }
        let k = Self.key(for: code)
        return hms[k] ?? learned[k]
    }

    /// Description for a print_error value, keyed by its decimal text — the same text the alert shows.
    func describePrintError(key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return err[key]
    }

    /// Description for a print_error value Bambuddy reported as a number.
    func describePrintError(_ code: Int?) -> String? {
        describePrintError(key: code.map { String($0) })
    }
}

extension AlertDescribe {
    /// Wire a loaded catalogue into `Alerts.present`.
    init(catalog: HmsCatalog) {
        self.init(
            hms: { catalog.describeHms($0) },
            printError: { catalog.describePrintError(key: $0) }
        )
    }
}

// MARK: - Parsing

extension HmsCatalog {
    /// Pure: Bambu's feed bytes -> the two lookup maps. Tolerates missing sections, odd casing, a
    /// numeric `ecode`, and outright garbage — a shape change upstream must never throw on the alerts
    /// screen.
    static func parseFeed(_ data: Data) -> (hms: [String: String], err: [String: String]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["data"] as? [String: Any]
        else { return ([:], [:]) }
        return (
            hms: entries(sections["device_hms"], uppercased: true),
            err: entries(sections["device_error"], uppercased: false)
        )
    }

    private static func entries(_ section: Any?, uppercased: Bool) -> [String: String] {
        guard let en = (section as? [String: Any])?["en"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        out.reserveCapacity(en.count)
        for e in en {
            let code = text(e["ecode"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let intro = text(e["intro"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, !intro.isEmpty else { continue }
            out[uppercased ? code.uppercased() : code] = intro
        }
        return out
    }

    /// The feed writes codes as strings, but a numeric one must not silently drop the entry.
    private static func text(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    /// Pure: pull the description out of a Bambu wiki HMS page.
    ///
    /// The page's og:title is `HMS_0C00-0100-0002-0017: Nozzle camera lens is dirty, …` — the code's
    /// own prefix is stripped so the caller gets just the sentence.
    static func parseWikiTitle(_ html: String) -> String? {
        let ogTitle = /(?i)<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/
        let titleTag = /(?i)<title>([^<]+)<\/title>/
        guard let matched = html.firstMatch(of: ogTitle)?.1 ?? html.firstMatch(of: titleTag)?.1 else { return nil }

        let siteSuffix = /(?i)\s*\|\s*Bambu Lab Wiki\s*$/
        let text = String(matched).replacing(siteSuffix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        // The whole title must be the `HMS_<code>: sentence` shape to strip the prefix; `.` never
        // spans a newline, so a multi-line title keeps its text intact rather than being truncated.
        let prefixed = /(?i)HMS_[0-9A-F_-]+:\s*(.+)/
        let body = text.wholeMatch(of: prefixed).map { String($0.1) } ?? text
        let out = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // A "title" of three characters or fewer is a 404 page or a placeholder, never a description.
        return out.count > 3 ? out : nil
    }
}

/// A code the feed doesn't carry, with the ordered candidate wiki pages to try. Built from the alert
/// itself, so the machine's own model family is tried first.
struct HmsLookupTarget: Sendable, Hashable {
    var code: String
    var urls: [String]
}

// MARK: - Load / learn

/// Memory -> disk -> network cache for the catalogue.
///
/// Never throws and never blocks a render: callers get `HmsCatalog.empty` until it resolves, and the
/// UI simply shows the code without prose in the meantime.
actor HmsCatalogStore {
    static let shared = HmsCatalogStore()

    /// Bambu's tables change on their own schedule, and the download is ~535 KB — a fortnight is
    /// fresh enough.
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    private let feedURL = URL(string: "https://e.bambulab.com/query.php?lang=en")!
    private let cacheURL: URL
    private let session: URLSession
    private var memo: HmsCatalog?
    /// The in-flight refresh, so a burst of callers costs one request.
    private var inflight: Task<HmsCatalog, Never>?

    init(session: URLSession = .shared, cacheDirectory: URL = URL.cachesDirectory) {
        self.session = session
        self.cacheURL = cacheDirectory.appending(path: "hms-catalog.json")
    }

    /// The catalogue, refreshing it if what we hold is older than `maxAge`.
    func load() async -> HmsCatalog {
        if let memo, Date().timeIntervalSince(memo.fetchedAt) < Self.maxAge { return memo }
        if let inflight { return await inflight.value }
        let task = Task<HmsCatalog, Never> { await self.refresh() }
        inflight = task
        let catalog = await task.value
        // Only the caller that started the refresh clears it, so a later one can't cancel a newer
        // request's single-flight slot.
        inflight = nil
        return catalog
    }

    private func refresh() async -> HmsCatalog {
        if let disk = readCache(), Date().timeIntervalSince(disk.fetchedAt) < Self.maxAge {
            memo = disk
            return disk
        }
        do {
            let (data, response) = try await session.data(from: feedURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let parsed = HmsCatalog.parseFeed(data)
            let catalog = HmsCatalog(hms: parsed.hms, err: parsed.err, learned: memo?.learned ?? [:], fetchedAt: Date())
            memo = catalog
            writeCache(catalog)
            return catalog
        } catch {
            return memo ?? .empty // offline: codes still render, just without prose
        }
    }

    /// Resolve codes the feed doesn't cover by reading Bambu's wiki page for them, and remember the
    /// answer.
    ///
    /// Every H2-family code is missing from the public feed, including the one that turned out to say
    /// "Nozzle camera lens is dirty…" — precisely the message worth surfacing. Candidate URLs come
    /// from the alert itself (model family first), and the first page that yields a title wins.
    @discardableResult
    func learn(_ targets: [HmsLookupTarget]) async -> HmsCatalog {
        var catalog = await load()
        var changed = false
        for target in targets {
            let key = HmsCatalog.key(for: target.code)
            if catalog.hms[key] != nil || catalog.learned[key] != nil { continue }
            for url in target.urls {
                if url.contains("/hms/error-code") { continue } // the index page describes nothing specific
                guard let parsed = URL(string: url) else { continue }
                do {
                    let (data, response) = try await session.data(from: parsed)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                    // Decoded leniently: a stray byte in the page must not cost us the description.
                    guard let description = HmsCatalog.parseWikiTitle(String(decoding: data, as: UTF8.self)) else { continue }
                    catalog.learned[key] = description
                    changed = true
                    break
                } catch {
                    break // offline — try again next launch
                }
            }
        }
        if changed {
            memo = catalog
            writeCache(catalog)
        }
        return memo ?? catalog
    }

    private func readCache() -> HmsCatalog? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(HmsCatalog.self, from: data)
    }

    private func writeCache(_ catalog: HmsCatalog) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        // Best-effort: a cache we can't write only costs one download next launch.
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

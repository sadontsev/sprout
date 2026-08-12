import Foundation

// MARK: - Wire types

/// One search or browse hit from `api.bambulab.com/v1/search-service`.
///
/// A hit carries enough for a grid tile and **nothing more** — no alphanumeric `modelId`, no
/// instances, no print time, no weight. Opening one still has to `POST /makerworld/resolve`, which
/// is why tapping a tile enters the existing detail flow rather than a second one.
struct MWSearchHit: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String?
    var slug: String?
    var cover: String?
    var license: String?
    var nsfw: Bool?
    var isExclusive: Bool?
    var likeCount: Int?
    var printCount: Int?
    var downloadCount: Int?
    var collectionCount: Int?
    var designCreator: Creator?

    struct Creator: Decodable, Hashable, Sendable {
        var name: String?
        var handle: String?
        var avatar: String?
    }
}

/// `{total, hits}`. `hits` is **null**, not `[]`, on a miss — which is exactly how the endpoint that
/// does not work announces itself (`design-service/design/search` answers `200 {"total":0,"hits":null}`).
struct MWSearchPage: Decodable, Hashable, Sendable {
    var total: Int?
    var hits: [MWSearchHit]?
}

/// One browse category from `homepage/nav`. `key` is what `select/design/nav?navKey=` wants.
struct MWNav: Decodable, Identifiable, Hashable, Sendable {
    var key: String
    var name: String?
    var type: Int?

    var id: String { key }
}

// MARK: - Client

/// Search and browse MakerWorld, called **directly from the app**.
///
/// Deliberately NOT part of `BambuddyClient`, and deliberately sharing none of its transport, auth or
/// error handling. Three reasons, in order of how much they matter:
///
/// 1. **Blast radius.** Every endpoint here is undocumented and reverse-engineered from Bambu's own
///    clients; Bambu can gate or change them without notice. Keeping them behind their own type means
///    the day that happens, only this feature breaks — nothing else in the app shares a code path
///    that would start throwing.
/// 2. **No credential ever leaves.** These calls are anonymous — verified — and nothing here can
///    reach the Keychain. The app must never hold a Bambu Cloud bearer; if these endpoints ever start
///    requiring one, search is **removed**, not worked around.
/// 3. **CAPTCHA risk lands on the phone, not the server.** A flagged phone IP costs browsing; a
///    flagged server IP would cost importing, which is the part that actually matters.
///
/// The User-Agent identifies this app honestly. Bambu Lab has been actively hostile to third parties
/// impersonating its own clients, and impersonation would be wrong regardless — never spoof Bambu
/// Studio or Handy headers to unblock something.
/// What `ExploreModel` needs from MakerWorld's search. A protocol only so the browse session's
/// orchestration — cancel-and-replace, the write barrier, paging — can be tested without a network,
/// which is where its actual bugs live. The app has exactly one conformance.
protocol MakerWorldSearching: Sendable {
    func search(_ keyword: String, offset: Int, limit: Int) async throws -> MWSearchPage
    func browse(navKey: String, offset: Int, limit: Int) async throws -> MWSearchPage
    func navs() async throws -> [MWNav]
}

extension MakerWorldSearching {
    func search(_ keyword: String, offset: Int = 0) async throws -> MWSearchPage {
        try await search(keyword, offset: offset, limit: 20)
    }
    func browse(navKey: String, offset: Int = 0) async throws -> MWSearchPage {
        try await browse(navKey: navKey, offset: offset, limit: 20)
    }
}

struct MakerWorldSearchClient: MakerWorldSearching, Sendable {
    private static let base = "https://api.bambulab.com/v1/search-service"
    private static let userAgent = "Sprout/1.0 (+https://github.com/sadontsev/sprout; personal 3D printer client)"

    /// Short, and with **no retry**. A stalled browse should fail and let the user try again rather
    /// than hold a spinner, and automatic retries against an undocumented endpoint are the fastest
    /// way to earn a rate limit.
    private let session: URLSession

    init(timeout: TimeInterval = 12) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept": "application/json"]
        // Ephemeral: nothing about browsing belongs in a persistent cookie or credential store.
        session = URLSession(configuration: cfg)
    }

    /// Free-text search.
    ///
    /// **`search-service/search/design`, not `design-service/design/search`.** The two sound like the
    /// same endpoint and are not: the second answers `200` with `total: 0, hits: null` from anywhere,
    /// which is what made "MakerWorld search doesn't work from a server" received wisdom.
    func search(_ keyword: String, offset: Int = 0, limit: Int = 20) async throws -> MWSearchPage {
        try await get("/search/design?keyword=\(esc(keyword))&offset=\(offset)&limit=\(limit)")
    }

    /// Browse one of `navs()`'s categories.
    func browse(navKey: String, offset: Int = 0, limit: Int = 20) async throws -> MWSearchPage {
        try await get("/select/design/nav?navKey=\(esc(navKey))&offset=\(offset)&limit=\(limit)")
    }

    /// The browse taxonomy, straight from MakerWorld rather than hardcoded — the category list is
    /// theirs to change, and a stale hardcoded copy would show categories that no longer exist.
    func navs() async throws -> [MWNav] {
        struct Envelope: Decodable { let navs: [MWNav]? }
        return try await get("/homepage/nav", as: Envelope.self).navs ?? []
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        guard let url = URL(string: Self.base + path) else {
            throw SproutError("Couldn’t build the MakerWorld search URL.")
        }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw MakerWorldSearchError(status: status)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw MakerWorldSearchError(status: -1)
        }
    }

    /// **No `.convertFromSnakeCase`.** This API is camelCase on the wire (`downloadCount`,
    /// `designCreator`), unlike Bambuddy's snake_case envelope — sharing Bambuddy's decoder would
    /// silently decode every one of these fields as nil.
    private static let decoder = JSONDecoder()

    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

/// A search failure, kept separate from `BambuddyError` so nothing outside this feature can catch it
/// by accident or report it as a problem with the user's own server.
struct MakerWorldSearchError: LocalizedError, Sendable {
    /// The HTTP status, `0` for no response, `-1` for a body that would not decode.
    var status: Int

    var errorDescription: String? {
        switch status {
        case 401, 403:
            // The end of the road by design: the app holds no Bambu Cloud token and must not.
            return "MakerWorld now requires a sign-in to search. You can still paste a model link."
        case 429:
            return "MakerWorld is rate-limiting searches. Try again shortly, or paste a model link."
        case 418:
            return "MakerWorld is challenging this device with a CAPTCHA. Pasting a link still works."
        case -1:
            return "MakerWorld returned something this app couldn’t read. Pasting a link still works."
        default:
            return "Couldn’t reach MakerWorld search. Pasting a model link still works."
        }
    }
}

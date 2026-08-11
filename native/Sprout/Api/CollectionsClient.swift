import Foundation

/// One of the owner's MakerWorld collections — a folder, not a model.
struct MakerWorldCollection: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    /// How many designs are in it. Carried from MakerWorld so an empty collection can be shown as
    /// empty without a round-trip per folder.
    var count: Int
    var cover: String?
    var isDefault: Bool?
}

/// The owner's MakerWorld collections, served by their own Trellis.
///
/// Collections are Bearer-gated and that bearer is the whole Bambu account, so it stays on the
/// server that already holds it — this app asks Trellis, which it already trusts and already sends
/// its API key to. Nothing here can reach a Bambu Cloud token, by construction.
///
/// Separate from `MakerWorldSearchClient` on purpose even though both end up showing the same tiles:
/// that one talks to Bambu anonymously and may be gated out of existence at any time, this one talks
/// to the owner's own machine. Different owners, different failure modes, different remedies.
struct CollectionsClient: Sendable {
    /// Trellis's base URL, already resolved from config. `nil` in LOCAL-only push mode, in which case
    /// there is no server to ask and the feature says so rather than showing nothing.
    let baseUrl: String?
    let apiKey: String

    var isAvailable: Bool { baseUrl != nil }

    func collections() async throws -> [MakerWorldCollection] {
        struct Envelope: Decodable { let collections: [MakerWorldCollection]? }
        return try await get("/makerworld/collections", as: Envelope.self).collections ?? []
    }

    /// The designs inside one collection. The hits are MakerWorld's own shape, passed straight
    /// through by Trellis, so `MWSearchHit` decodes them and the search tile renders them unchanged.
    func designs(in collectionId: Int, offset: Int = 0, limit: Int = 20) async throws -> MWSearchPage {
        try await get("/makerworld/collections/\(collectionId)/designs?offset=\(offset)&limit=\(limit)",
                      as: MWSearchPage.self)
    }

    /// Which collections currently contain this design — what draws the checkmarks.
    func collections(containing designId: Int) async throws -> Set<Int> {
        struct Envelope: Decodable { let collections: [Int]? }
        return Set(try await get("/makerworld/designs/\(designId)/collections", as: Envelope.self)
            .collections ?? [])
    }

    /// Add or remove ONE collection, leaving the design's other memberships alone.
    ///
    /// The upstream call replaces a design's entire membership, so the server does a read-union-write.
    /// That is deliberately not done here: doing it in the app would put the read and the write on
    /// opposite sides of a slow link, widening the window in which a partial answer becomes a `PUT`
    /// that un-collects things.
    @discardableResult
    func setMembership(design designId: Int, collection collectionId: Int, member: Bool) async throws -> Set<Int> {
        struct Result: Decodable { let collections: [Int]? }
        let r: Result = try await send("/makerworld/collections/\(collectionId)/designs/\(designId)",
                                       method: member ? "PUT" : "DELETE", as: Result.self)
        return Set(r.collections ?? [])
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(path, method: "GET", as: type)
    }

    private func send<T: Decodable>(_ path: String, method: String, as type: T.Type) async throws -> T {
        guard let url = LiveActivityController.endpoint(baseUrl, path) else {
            throw SproutError("Collections need a push server. Set one in Settings, or leave this off.")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Trellis answers with the REASON, and the reason is the whole point: "your Bambuddy
            // isn't signed in to Bambu Cloud" and "MakerWorld refused" are different machines to go
            // and look at. Replacing that with "couldn't load collections" throws it away.
            throw SproutError(Self.detail(data) ?? "Couldn’t load your collections (HTTP \(status)).")
        }
        // `.convertFromSnakeCase` serves BOTH shapes: Trellis's own `is_default` becomes `isDefault`,
        // while MakerWorld's already-camelCase hit keys contain no underscores and pass through.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Foundation's own text here is "The data couldn't be read because it isn't in the
            // correct format", which tells the owner nothing about which of three machines to look
            // at. A decode failure means Trellis answered with a shape this build does not know —
            // in practice, the two are out of step.
            throw SproutError("Your push server sent collections in a shape this app doesn’t "
                              + "recognise. Update Trellis and the app to matching versions.")
        }
    }

    private static func detail(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["detail"] as? String, !d.isEmpty
        else { return nil }
        return d
    }
}

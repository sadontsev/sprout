import Foundation
import Observation

/// The MakerWorld browse session: what was searched, what came back, and where the user is in it.
///
/// **Why this is a model and not `@State` on the panel.** Every one of these used to be `@State`
/// inside `MakerWorldPanel`, which is mounted by a `fullScreenCover`. Dismissing that cover unmounts
/// the view, so `hits`, `activeQuery`, `activeNav`, `collections` and `navs` were destroyed on the
/// way out and three `.task`s re-ran on the way back in. Getting from a model to the results you
/// found it in was impossible, and re-entering Explore always showed an empty field. Lifting the
/// session out of the view is what makes "back" mean anything.
///
/// Owned by `Shell` and passed through the environment rather than added to `AppModel`: it is a
/// browse session, not app-wide state, and `Shell` outlives the cover.
@Observable
@MainActor
final class ExploreModel {

    // MARK: What is on screen

    /// The text in the search field. Not the query the results belong to — see `activeQuery`.
    var query = ""
    var hits: [MWSearchHit] = []
    var hitTotal: Int?
    var searchError: String?
    var navs: [MWNav] = []
    /// The browse category currently listed, or nil when the grid is showing a text search.
    var activeNav: String?
    /// The query the visible hits belong to. Paging has to repeat it, and the field may have moved
    /// on — this is also the write barrier that stops a slow response overwriting a newer one.
    var activeQuery: String?
    var sort: MakerWorldSearch.Sort = .relevance
    var recent: [MakerWorldRecentImport] = []
    /// What is pushed on top of the results. In the model rather than the view so that dismissing
    /// Explore and coming back returns to where you were, which is the whole point of F2.
    var path: [MWSearchHit] = []
    var access: MakerWorldAccess = .checking

    /// True while a result set is being fetched. The grid keeps its old content underneath — see
    /// `startFetch`, and C5 in the design handoff: blanking first makes a request read as slower
    /// than it is.
    private(set) var loading = false
    private(set) var loadingMore = false

    // MARK: Collections

    var collections: [MakerWorldCollection] = []
    /// True when the folder list, rather than a grid of designs, is what Explore is showing.
    var showingCollections = false
    /// The folder whose designs are in the grid, if any.
    var activeCollection: MakerWorldCollection?

    // MARK: Wiring

    /// Search and browse talk to MakerWorld DIRECTLY — see `MakerWorldSearchClient` for why none of
    /// this shares Bambuddy's transport, and why the app never holds a Bambu Cloud bearer.
    let searchClient: any MakerWorldSearching

    init(searchClient: any MakerWorldSearching = MakerWorldSearchClient()) {
        self.searchClient = searchClient
    }

    /// The fetch currently in flight, held so the next one can cancel it.
    ///
    /// This replaces the `guard !searching` that used to open every entry point. That guard DROPPED
    /// input: tapping a category while a search was running did nothing at all, which is the most
    /// "broken app" feeling there is. Cancel-and-replace serves the last thing the user asked for,
    /// and `activeQuery`/`activeNav` still act as the write barrier so a straggler cannot land.
    private var fetch: Task<Void, Never>?

    /// What was on screen before the current mode was entered, so leaving it is instant and lands
    /// where the user actually was.
    ///
    /// The bug this fixes: tapping "My collections" during a search replaced the results with the
    /// folder list, the chip rendered as selected, and **nothing turned it off**. The query was
    /// still in the field, so the app looked like it was showing a search it had thrown away. A
    /// control that can be switched on must be able to be switched off, and "off" has to mean
    /// something — here it means the results you were looking at, restored without a refetch.
    private var previous: Snapshot?

    private struct Snapshot {
        var query: String?
        var nav: String?
        var hits: [MWSearchHit]
        var total: Int?
        var sort: MakerWorldSearch.Sort
    }

    /// True when there is a mode to leave — drives whether a selected chip is a toggle.
    var canExitMode: Bool { showingCollections || activeCollection != nil || activeNav != nil }

    /// Remember the result set being replaced, but only if it is one worth coming back to.
    private func rememberCurrent() {
        guard activeQuery != nil || activeNav != nil, !showingCollections, activeCollection == nil
        else { return }
        previous = Snapshot(query: activeQuery, nav: activeNav, hits: hits, total: hitTotal, sort: sort)
    }

    /// Turn the current mode off and go back to what was underneath.
    ///
    /// Restores from the snapshot rather than refetching: the results were correct when they were
    /// replaced, and a round trip to un-tap a chip would make leaving slower than entering.
    func exitMode() {
        // You cannot leave a mode you are not in. Without this guard, calling it while a plain
        // search is showing takes the no-snapshot branch and wipes the live results — which a test
        // caught: search, enter collections, search again, exit → an empty grid and no query.
        guard canExitMode else { return }
        fetch?.cancel()
        loading = false
        showingCollections = false
        activeCollection = nil
        searchError = nil

        if let previous {
            activeQuery = previous.query
            activeNav = previous.nav
            hits = previous.hits
            hitTotal = previous.total
            sort = previous.sort
            self.previous = nil
        } else {
            // Nothing underneath — go back to the cold screen rather than an empty grid that looks
            // like a search returning nothing.
            activeQuery = nil
            activeNav = nil
            hits = []
            hitTotal = nil
            sort = .relevance
        }
    }

    /// Resolve responses for this session, keyed by model id, so back-then-forward is instant.
    private var resolveCache: [Int: MakerWorldResolved] = [:]

    // MARK: Derived

    /// What the field's contents mean. The button label and the live-search suggestion both read it.
    var intent: MakerWorldSearch.Intent { MakerWorldSearch.intent(for: query) }

    /// The hits in the order they should be displayed.
    var orderedHits: [MWSearchHit] { MakerWorldSearch.sorted(hits, by: sort) }

    var hasMore: Bool { MakerWorldSearch.hasMore(loaded: hits.count, total: hitTotal) }

    /// True when nothing has been asked for yet — the state that should show shelves, not an empty
    /// field.
    var isCold: Bool { activeQuery == nil && activeNav == nil && activeCollection == nil && !showingCollections }

    // MARK: Fetching

    /// One entry point for every result set, so the reset, the cancel and the write barrier cannot
    /// drift apart between search, browse and collections — they did, and each had its own subtly
    /// different reset list.
    ///
    /// `keepContent` is what stops the grid flashing empty: the outgoing hits stay until the new page
    /// lands (the view dims them under a skeleton). They are only cleared when the *kind* of thing on
    /// screen changes, where keeping them would be a lie about what you are looking at.
    private func startFetch(keepContent: Bool = true,
                            _ work: @escaping @MainActor (ExploreModel) async throws -> Void) {
        fetch?.cancel()
        searchError = nil
        sort = .relevance          // a sort carried into a new result set reorders it unasked
        if !keepContent {
            hits = []
            hitTotal = nil
        }
        loading = true
        fetch = Task { @MainActor in
            defer { loading = false }
            do {
                try await work(self)
            } catch is CancellationError {
                // A newer request replaced this one. Not a failure, and reporting it as one would
                // put an error on screen every time someone types.
            } catch {
                guard !Task.isCancelled else { return }
                // The client's own sentence. For collections that names WHICH machine is at fault,
                // which "couldn't load" would throw away.
                searchError = error.localizedDescription
            }
        }
    }

    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        showingCollections = false
        activeCollection = nil
        activeNav = nil
        activeQuery = trimmed
        previous = nil          // searching IS the way out; there is nothing left to go back to
        startFetch { m in
            let page = try await m.searchClient.search(trimmed)
            guard m.activeQuery == trimmed else { return }   // a newer query won
            m.hits = page.hits ?? []
            m.hitTotal = page.total
        }
    }

    func browse(_ nav: MWNav) {
        rememberCurrent()
        showingCollections = false
        activeCollection = nil
        activeQuery = nil
        activeNav = nav.key
        startFetch { m in
            let page = try await m.searchClient.browse(navKey: nav.key)
            guard m.activeNav == nav.key else { return }
            m.hits = page.hits ?? []
            m.hitTotal = page.total
        }
    }

    /// The owner's own collections, from their Trellis.
    ///
    /// `laPushUrl`, **not** `resolvePushUrl`: collections are plain authenticated HTTP with no APNs
    /// involved, so they must not disappear when Live-Activity push is switched off.
    func openCollections(_ client: CollectionsClient) {
        rememberCurrent()
        showingCollections = true
        activeCollection = nil
        activeNav = nil
        activeQuery = nil
        // The grid is being replaced by a folder LIST, so keeping designs underneath would show
        // content that has nothing to do with what is loading.
        startFetch(keepContent: false) { m in
            m.collections = try await client.collections()
        }
    }

    /// Leave a folder for the folder list. Instant when the list is still in hand — the collections
    /// have not changed in the seconds since they loaded.
    func backToCollections(_ client: CollectionsClient) {
        activeCollection = nil
        hits = []
        hitTotal = nil
        searchError = nil
        if collections.isEmpty {
            openCollections(client)
        } else {
            showingCollections = true
        }
    }

    func openCollection(_ folder: MakerWorldCollection, client: CollectionsClient) {
        showingCollections = false
        activeCollection = folder
        activeNav = nil
        activeQuery = nil
        startFetch(keepContent: false) { m in
            let page = try await client.designs(in: folder.id)
            guard m.activeCollection?.id == folder.id else { return }
            m.hits = page.hits ?? []
            m.hitTotal = page.total
        }
    }

    /// Fetch the next page. Driven by a tile appearing near the end of the grid rather than by a
    /// button, so it must be safe to call repeatedly and while another page is in flight.
    func loadMore(_ client: CollectionsClient) {
        guard hasMore, !loadingMore, !loading else { return }
        let offset = hits.count
        let nav = activeNav, q = activeQuery, folder = activeCollection
        loadingMore = true
        Task { @MainActor in
            defer { loadingMore = false }
            do {
                let page: MWSearchPage
                if let folder {
                    page = try await client.designs(in: folder.id, offset: offset)
                } else if let nav {
                    page = try await searchClient.browse(navKey: nav, offset: offset)
                } else if let q {
                    page = try await searchClient.search(q, offset: offset)
                } else {
                    return
                }
                // The same result set must still be on screen, or this page belongs to nothing.
                guard activeNav == nav, activeQuery == q, activeCollection?.id == folder?.id else { return }
                // merge, not append: the endpoint's ordering is unstable between calls, so paging by
                // offset genuinely repeats models — and duplicate ForEach ids are undefined
                // behaviour, not a cosmetic wart.
                hits = MakerWorldSearch.merge(hits, page.hits ?? [])
                hitTotal = page.total ?? hitTotal
            } catch {
                // A failed page is not worth an error banner over content that is already good.
            }
        }
    }

    /// How many hits to gather before a local sort is worth trusting.
    ///
    /// Client-side sorting can only order what has been loaded. With 20 of 10 000 that is "the most
    /// downloaded of an arbitrary 20" — true, useless, and easily mistaken for "the most downloaded
    /// on MakerWorld". Pulling a few more pages first makes the answer mean something; the UI still
    /// states the scope, because even 100 of 10 000 is a sample.
    static let poolForLocalSort = 100

    /// Pull pages until the pool is deep enough to sort, or there are no more.
    ///
    /// Bounded twice — by the target and by `hasMore` — because an unbounded loop against an
    /// undocumented endpoint is the fastest way to earn a rate limit.
    func deepenPool(_ client: CollectionsClient) {
        guard sort.wantsDeeperPool, hasMore, hits.count < Self.poolForLocalSort else { return }
        Task { @MainActor in
            var guardRail = 0
            while sort.wantsDeeperPool, hasMore, hits.count < Self.poolForLocalSort, guardRail < 8 {
                guardRail += 1
                let before = hits.count
                loadMore(client)
                // Wait for the page this started, rather than spinning.
                while loadingMore { await Task.yield() }
                if hits.count == before { break }   // no progress: stop rather than loop
            }
        }
    }

    // MARK: Resolve

    /// A resolve already in hand for this model, if any. The detail page shows it on the first frame
    /// instead of spinning.
    func cachedResolve(_ modelId: Int) -> MakerWorldResolved? { resolveCache[modelId] }

    func cacheResolve(_ resolved: MakerWorldResolved, for modelId: Int) {
        resolveCache[modelId] = resolved
    }
}

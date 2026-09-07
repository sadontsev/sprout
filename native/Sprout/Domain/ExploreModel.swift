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
    private(set) var sort: MakerWorldSearch.Sort = .relevance
    private(set) var filters = MWSearchFilters()
    /// The first page's `searchSessionId`, echoed on later pages so paging stays on one ranking.
    private var sessionId: String?
    /// A page that failed mid-scroll. Shown under the grid; a 429 must not look like the end.
    var loadMoreError: String?
    /// Typeahead for what is in the field.
    var suggestions: [String] = []
    /// Cold-screen content, fetched once per session.
    var trending: [MWSearchHit] = []
    var hotWords: [String] = []
    private var coldStartLoaded = false
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
    }

    /// True when there is a mode to leave — drives whether a selected chip is a toggle.
    var canExitMode: Bool { showingCollections || activeCollection != nil || activeNav != nil }

    /// Remember the result set being replaced, but only if it is one worth coming back to.
    private func rememberCurrent() {
        guard !isCold, !showingCollections, activeCollection == nil else { return }
        previous = Snapshot(query: activeQuery, nav: activeNav, hits: hits, total: hitTotal)
    }

    /// Turn the current mode off and go back to what was underneath.
    ///
    /// Collections restore from a snapshot: the results were correct when they were replaced, and
    /// a round trip to un-tap a chip would make leaving slower than entering. A category is not a
    /// snapshot mode any more — it narrows the keyword — so leaving it refetches the keyword alone.
    func exitMode() {
        // You cannot leave a mode you are not in. Without this guard, calling it while a plain
        // search is showing takes the no-snapshot branch and wipes the live results — which a test
        // caught: search, enter collections, search again, exit → an empty grid and no query.
        guard canExitMode else { return }
        fetch?.cancel()
        loading = false
        searchError = nil

        if showingCollections || activeCollection != nil {
            showingCollections = false
            activeCollection = nil
            if let previous {
                activeQuery = previous.query
                activeNav = previous.nav
                hits = previous.hits
                hitTotal = previous.total
                self.previous = nil
            } else {
                // Nothing underneath — go back to the cold screen rather than an empty grid that
                // looks like a search returning nothing.
                activeQuery = nil
                activeNav = nil
                hits = []
                hitTotal = nil
            }
            return
        }

        if activeNav == "Trending" { sort = .relevance }
        activeNav = nil
        if isCold {
            hits = []
            hitTotal = nil
        } else {
            fetchCurrent()
        }
    }

    /// Resolve responses for this session, keyed by model id, so back-then-forward is instant.
    private var resolveCache: [Int: MakerWorldResolved] = [:]

    // MARK: Derived

    /// What the field's contents mean. The button label and the live-search suggestion both read it.
    var intent: MakerWorldSearch.Intent { MakerWorldSearch.intent(for: query) }

    var hasMore: Bool { MakerWorldSearch.hasMore(loaded: hits.count, total: hitTotal) }

    /// True when nothing has been asked for yet — the state that should show shelves, not an empty
    /// grid. Filters count as asking: filters alone browse everything, filtered. So does a chosen
    /// order: an order with no keyword browses everything in that order.
    var isCold: Bool {
        activeQuery == nil && activeNav == nil && filters.isEmpty && sort == .relevance
            && activeCollection == nil && !showingCollections
    }

    /// The one request the screen is showing, at a given offset. Every fetch builds it from here,
    /// and equality against it is the write barrier: a response only lands if the screen still
    /// asks the same question.
    func currentRequest(offset: Int = 0) -> MWSearchRequest {
        var r = MWSearchRequest()
        r.keyword = activeQuery
        r.categoryId = MakerWorldSearch.categoryId(navKey: activeNav)
        r.sort = activeNav == "Trending" ? .trending : sort
        r.filters = filters
        r.offset = offset
        r.sessionId = offset == 0 ? nil : sessionId
        return r
    }

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
        activeQuery = trimmed
        suggestions = []
        // A keyword means "rank this": Relevance, unless the Trending chip is on, where the
        // keyword narrows the trending order instead.
        if activeNav != "Trending" { sort = .relevance }
        previous = nil          // searching IS the way out; there is nothing left to go back to
        fetchCurrent()
    }

    /// A category narrows whatever keyword is in force; "Trending" is the trending order alone.
    func browse(_ nav: MWNav) {
        showingCollections = false
        activeCollection = nil
        activeNav = nav.key
        if nav.key == "Trending" { sort = .trending }
        fetchCurrent()
    }

    func setSort(_ new: MakerWorldSearch.Sort) {
        guard new != sort || activeNav == "Trending" else { return }
        if activeNav == "Trending", new != .trending { activeNav = nil }
        sort = new
        if !isCold {
            fetchCurrent()
        } else {
            hits = []
            hitTotal = nil
        }
    }

    /// Applied whole, from the sheet's Done: one request per edit session, not one per toggle.
    func setFilters(_ new: MWSearchFilters) {
        guard new != filters else { return }
        filters = new
        if isCold {
            hits = []
            hitTotal = nil
        } else {
            fetchCurrent()
        }
    }

    /// Fetch page one of `currentRequest()`. Shared by search, browse, sort, filters and refresh
    /// so the reset, the cancel and the write barrier cannot drift apart between them.
    private func fetchCurrent() {
        let request = currentRequest()
        startFetch { m in
            let page = try await m.searchClient.page(request)
            guard m.currentRequest() == request else { return }   // the screen moved on
            m.hits = page.hits ?? []
            m.hitTotal = page.total
            m.sessionId = page.searchSessionId
            m.loadMoreError = nil
        }
    }

    /// Typeahead for the field. Written only while the field still says what was asked about.
    func suggest(_ text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { suggestions = []; return }
        Task { @MainActor in
            let found = (try? await searchClient.suggest(term)) ?? []
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
            suggestions = Array(found.prefix(6))
        }
    }

    /// The cold screen's own content: one trending page and the hot-word row. Once per session;
    /// a shelf that refetched on every visit would make the cold screen slower than search.
    func loadColdStart() {
        guard !coldStartLoaded else { return }
        coldStartLoaded = true
        var request = MWSearchRequest()
        request.sort = .trending
        request.limit = 20
        Task { @MainActor in
            if let page = try? await searchClient.page(request) { trending = page.hits ?? [] }
        }
        Task { @MainActor in
            hotWords = Array(((try? await searchClient.hotWords()) ?? []).prefix(8))
        }
    }

    /// Imports in flight, and how the last one for each model ended.
    ///
    /// On the MODEL, not on the inspector, for exactly the reason the doc comment at the top of this
    /// file gives about `hits`. The inspector is rebuilt whenever the section changes and unmounted
    /// whenever `.inspector(isPresented:)` closes — which `⌥⌘I` does — so as `@State` this was
    /// destroyed mid-download. The button then read "Import to Library" and was enabled while the
    /// same import was still running, so pressing it started a second one.
    ///
    /// Keyed by model id because several can be in flight: the copy says browsing continues, and
    /// a single in-flight slot would make that a lie the moment someone clicked another model.
    var imports: [Int: MakerWorldImportState] = [:]

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

    /// Re-issue the fetch behind whatever is currently on screen — macOS's `⌘R` (§7).
    ///
    /// Deliberately NOT implemented by calling `search`/`browse`/`openCollection` again. Those are
    /// NAVIGATION: each rewrites the `active*` fields, and `browse` and `openCollections` also call
    /// `rememberCurrent()` — so refreshing through them would push a duplicate entry onto the back
    /// stack on every `⌘R`, and "Back" would walk through a history of the same screen. Refreshing
    /// is "fetch the same thing again"; the mode has already been decided.
    func refresh(_ client: CollectionsClient) {
        if showingCollections {
            startFetch(keepContent: false) { m in
                m.collections = try await client.collections()
            }
        } else if let folder = activeCollection {
            startFetch { m in
                let page = try await client.designs(in: folder.id)
                guard m.activeCollection?.id == folder.id else { return }
                m.hits = page.hits ?? []
                m.hitTotal = page.total
            }
        } else if !isCold {
            fetchCurrent()
        }
        // Cold start: nothing has been asked for, so there is nothing to ask for again. Not an
        // error, and not a no-op worth reporting — the grid is already showing the cold shelves.
    }

    /// Fetch the next page. Driven by a tile appearing near the end of the grid rather than by a
    /// button, so it must be safe to call repeatedly and while another page is in flight.
    func loadMore(_ client: CollectionsClient) {
        guard hasMore, !loadingMore, !loading else { return }
        let offset = hits.count
        let folder = activeCollection
        let request = currentRequest(offset: offset)
        loadingMore = true
        Task { @MainActor in
            defer { loadingMore = false }
            do {
                let page: MWSearchPage
                if let folder {
                    page = try await client.designs(in: folder.id, offset: offset)
                    guard activeCollection?.id == folder.id else { return }
                } else {
                    page = try await searchClient.page(request)
                    // The same result set must still be on screen, or this page belongs to nothing.
                    guard currentRequest(offset: offset) == request else { return }
                }
                // merge, not append: the endpoint's ordering is unstable between calls, so paging by
                // offset genuinely repeats models — and duplicate ForEach ids are undefined
                // behaviour, not a cosmetic wart.
                hits = MakerWorldSearch.merge(hits, page.hits ?? [])
                hitTotal = page.total ?? hitTotal
                loadMoreError = nil
            } catch is CancellationError {
            } catch {
                loadMoreError = error.localizedDescription
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

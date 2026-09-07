import XCTest
@testable import Sprout

/// A search client the test drives by hand.
///
/// Each call parks on a continuation until the test releases it, which is the only way to get a
/// second request in flight while the first is still pending — and "two requests in flight" is
/// precisely the situation the old `guard !searching` got wrong.
private actor FakeSearch: MakerWorldSearching {
    private var pending: [String: CheckedContinuation<MWSearchPage, Error>] = [:]
    private(set) var requests: [MWSearchRequest] = []

    /// The key a request parks under: keyword, category, sort, offset. Filters and the session
    /// id are read back off `requests` instead, so a test asserting them cannot pass by accident.
    static func key(_ keyword: String?, cat: Int? = nil,
                    sort: MakerWorldSearch.Sort = .relevance, offset: Int = 0) -> String {
        "page:\(keyword ?? "")|\(cat.map(String.init) ?? "")|\(sort.rawValue)|\(offset)"
    }

    private static func key(for r: MWSearchRequest) -> String {
        key(r.keyword, cat: r.categoryId, sort: r.sort, offset: r.offset)
    }

    func page(_ request: MWSearchRequest) async throws -> MWSearchPage {
        requests.append(request)
        return try await park(Self.key(for: request))
    }

    func navs() async throws -> [MWNav] { [] }
    func suggest(_ keyword: String) async throws -> [String] { ["\(keyword) holder", "\(keyword) case"] }
    func hotWords() async throws -> [String] { ["halloween"] }

    private func park(_ key: String) async throws -> MWSearchPage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in pending[key] = c }
        } onCancel: {
            Task { await self.fail(key, CancellationError()) }
        }
    }

    /// Let a parked call return.
    func finish(_ key: String, hits: [Int], total: Int? = nil, session: String? = nil) {
        pending.removeValue(forKey: key)?
            .resume(returning: MWSearchPage(total: total ?? hits.count,
                                            hits: hits.map { MWSearchHit(id: $0) },
                                            searchSessionId: session))
    }

    func fail(_ key: String, _ error: Error) {
        pending.removeValue(forKey: key)?.resume(throwing: error)
    }

    func isParked(_ key: String) -> Bool { pending[key] != nil }
    func callCount() -> Int { requests.count }
}

@MainActor
final class ExploreModelTests: XCTestCase {

    /// Wait until a condition holds, rather than yielding a fixed number of times and hoping.
    ///
    /// A fixed spin was flaky: `startFetch` hands off to a detached Task, and on a loaded machine
    /// twelve yields is sometimes not enough for it to reach its first suspension point. A test that
    /// passes on an idle laptop and fails during a simulator boot is worse than no test — it teaches
    /// you to ignore red.
    private func waitUntil(_ condition: () -> Bool,
                           _ message: String = "condition never held",
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message, file: file, line: line)
    }

    /// Let whatever was just started reach its first suspension point. Used where there is no
    /// condition to wait on yet — the assertion that follows is the real check.
    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    // MARK: Derived state

    func testColdUntilSomethingIsAskedFor() {
        let m = ExploreModel(searchClient: FakeSearch())
        XCTAssertTrue(m.isCold, "a fresh session shows shelves, not an empty result set")
        m.activeQuery = "benchy"
        XCTAssertFalse(m.isCold)
    }

    func testHasMoreComesFromTheReportedTotal() {
        let m = ExploreModel(searchClient: FakeSearch())
        m.hits = [MWSearchHit(id: 1)]
        XCTAssertFalse(m.hasMore, "no total means no claim about more")
        m.hitTotal = 1
        XCTAssertFalse(m.hasMore)
        m.hitTotal = 40
        XCTAssertTrue(m.hasMore)
    }

    // MARK: C4 — input is served, not dropped

    /// The bug this replaces: every entry point opened with `guard !searching`, so tapping a category
    /// while a search was in flight did *nothing at all*. Today a category NARROWS the keyword: both
    /// stay set and one request carries both.
    func testTappingACategoryDuringASearchNarrowsIt() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)

        m.search("benchy")
        await waitUntil({ m.loading }, "the search never started")
        var inFlight = false
        for _ in 0..<2000 where !inFlight { inFlight = await fake.isParked(FakeSearch.key("benchy")); await Task.yield() }
        XCTAssertTrue(inFlight, "the search should be in flight")

        m.browse(MWNav(key: "category_400", name: "Household"))
        await settle()

        let requests = await fake.requests
        XCTAssertEqual(requests.count, 2, "the category tap must be served")
        XCTAssertEqual(requests.last?.keyword, "benchy")
        XCTAssertEqual(requests.last?.categoryId, 400)
        XCTAssertEqual(m.activeNav, "category_400")
        XCTAssertEqual(m.activeQuery, "benchy", "the keyword still owns the grid; the category narrows it")
    }

    /// Cancel-and-replace is only half of it: the loser must not be able to write its results.
    func testASupersededSearchCannotOverwriteTheNewerOne() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)

        m.search("first")
        await settle()
        m.search("second")
        await settle()

        // The first request lands LATE, after the second already owns the grid.
        await fake.finish(FakeSearch.key("first"), hits: [111])
        await fake.finish(FakeSearch.key("second"), hits: [222])
        await waitUntil({ !m.hits.isEmpty }, "neither response ever landed")

        XCTAssertEqual(m.hits.map(\.id), [222], "the stale response must not land")
        XCTAssertEqual(m.activeQuery, "second")
    }

    /// A cancelled request is not a failure, and must not put an error on screen — with live search
    /// that would mean an error banner on nearly every keystroke.
    func testCancellationIsNotReportedAsAnError() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("first")
        await settle()
        m.search("second")
        await settle()
        await fake.finish(FakeSearch.key("second"), hits: [1])
        await settle()
        XCTAssertNil(m.searchError)
    }

    func testARealFailureIsReportedWithTheClientsOwnSentence() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.fail(FakeSearch.key("benchy"), SproutError("MakerWorld refused the request."))
        await waitUntil({ m.searchError != nil }, "the failure never surfaced")
        XCTAssertEqual(m.searchError, "MakerWorld refused the request.")
    }

    // MARK: C5 — never blank the grid

    /// Blanking first makes a request read as slower than it is. The outgoing hits stay until the
    /// replacement lands; the view dims them under a skeleton.
    func testResultsSurviveUntilTheReplacementArrives() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("first")
        await settle()
        await fake.finish(FakeSearch.key("first"), hits: [1, 2, 3])
        await waitUntil({ m.hits.count == 3 }, "the first page never landed")
        XCTAssertEqual(m.hits.count, 3)

        m.search("second")
        await settle()
        XCTAssertEqual(m.hits.map(\.id), [1, 2, 3], "the grid must not flash empty mid-request")
        XCTAssertTrue(m.loading)

        await fake.finish(FakeSearch.key("second"), hits: [9])
        await waitUntil({ m.hits.map(\.id) == [9] }, "the replacement never landed")
        XCTAssertEqual(m.hits.map(\.id), [9])
        XCTAssertFalse(m.loading)
    }

    /// …except when the KIND of thing on screen changes. Designs left under a loading folder list
    /// would be content that has nothing to do with what was asked for.
    func testSwitchingToTheFolderListClearsTheDesignsUnderneath() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("first")
        await settle()
        await fake.finish(FakeSearch.key("first"), hits: [1, 2])
        await waitUntil({ m.hits.count == 2 }, "the search never landed")

        m.openCollections(CollectionsClient(baseUrl: nil, apiKey: ""))
        await settle()
        XCTAssertTrue(m.hits.isEmpty)
        XCTAssertTrue(m.showingCollections)
    }

    // MARK: Sorting — the server's, now

    /// A keyword search means "rank this for me": it resets the order to Relevance.
    func testANewSearchResetsTheSortToRelevance() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.setSort(.downloads)
        m.search("benchy")
        XCTAssertEqual(m.sort, .relevance, "the reset is synchronous — it must not wait on the network")
    }

    /// Changing the order is a new request, not a local shuffle.
    func testChangingTheSortRefetchesWithTheServerOrder() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish(FakeSearch.key("benchy"), hits: [1, 2])
        await waitUntil({ m.hits.count == 2 })

        m.setSort(.downloads)
        await settle()
        XCTAssertEqual(m.hits.map(\.id), [1, 2], "the old order stays on screen until the new page lands")
        await fake.finish(FakeSearch.key("benchy", sort: .downloads), hits: [2, 1])
        await waitUntil({ m.hits.map(\.id) == [2, 1] }, "the re-sorted page never landed")
        let last = await fake.requests.last
        XCTAssertEqual(last?.sort, .downloads)
    }

    /// The Trending chip is the trending ORDER with no keyword. Picking another order turns it off
    /// rather than leaving a chip lit that no longer describes the grid.
    func testTrendingChipIsTheTrendingOrder() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.browse(MWNav(key: "Trending", name: "Trending"))
        await settle()
        let first = await fake.requests.last
        XCTAssertEqual(first?.sort, .trending)
        XCTAssertNil(first?.categoryId)
        XCTAssertNil(first?.keyword)

        m.setSort(.likes)
        XCTAssertNil(m.activeNav, "another order is not Trending any more")
        await settle()
        let last = await fake.requests.last
        XCTAssertEqual(last?.sort, .likes, "another order browses everything in that order")
    }

    // MARK: Filters

    func testFiltersRideEveryRequestAndCountForTheBadge() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        var f = MWSearchFilters()
        f.printerCode = "O1C2"
        f.maxMinutes = 180
        m.setFilters(f)
        await settle()
        let last = await fake.requests.last
        XCTAssertEqual(last?.filters, f)
        XCTAssertEqual(m.filters.activeCount, 2)
        XCTAssertFalse(m.isCold, "filters alone are something to show")
    }

    /// Filters without a keyword browse everything, filtered — the site does the same.
    func testFiltersAloneAreARequest() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        var f = MWSearchFilters(); f.customisable = true
        m.setFilters(f)
        await settle()
        let last = await fake.requests.last
        XCTAssertNil(last?.keyword)
        XCTAssertTrue(last?.filters.customisable ?? false)
    }

    /// A folder is not a MakerWorld result set, and the controls that say so are in the VIEW —
    /// so the model has to refuse as well. Sorting inside a folder used to build the request
    /// "everything on MakerWorld, by likes" (no keyword, no category, because `currentRequest()`
    /// has neither in a collection), fetch it, and drop the answer into the grid with the folder
    /// still selected.
    func testSortAndFiltersInsideAFolderDoNotReplaceItWithABrowse() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        let collections = CollectionsClient(baseUrl: nil, apiKey: "")

        m.search("spool")
        await settle()
        await fake.finish(FakeSearch.key("spool"), hits: [1, 2], total: 2)
        await waitUntil({ m.hits.count == 2 }, "the search never landed")

        m.openCollections(collections)
        await settle()
        let folder = MakerWorldCollection(id: 7, title: "Prints", count: 3)
        m.openCollection(folder, client: collections)
        await settle()
        XCTAssertFalse(m.acceptsMakerWorldRequest, "a folder cannot answer a sort or a filter")
        let before = await fake.callCount()

        m.setSort(.likes)
        var f = MWSearchFilters()
        f.customisable = true
        m.setFilters(f)
        await settle()

        let after = await fake.callCount()
        XCTAssertEqual(after, before, "neither control may issue a MakerWorld request from a folder")
        XCTAssertEqual(m.activeCollection?.id, 7, "the folder is still what is on screen")
        XCTAssertEqual(m.sort, .relevance, "a refused sort must not be recorded either")
        XCTAssertTrue(m.filters.isEmpty)
    }

    /// Going cold is a state, not just an empty array: the error belonging to the request that is
    /// no longer being made has to go with it. Clearing the last filter used to leave a 429 sitting
    /// over the shelves — the one screen that has asked for nothing reporting that it had failed.
    func testGoingColdClearsTheErrorsAsWellAsTheResults() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)

        var f = MWSearchFilters()
        f.customisable = true
        m.setFilters(f)                       // filters alone are a request
        await settle()
        await fake.fail(FakeSearch.key(nil), MakerWorldSearchError(status: 429))
        await waitUntil({ m.searchError != nil }, "the failure never landed")
        m.loadMoreError = "a page that failed earlier"

        m.setFilters(MWSearchFilters())       // …and clearing them is going cold
        await settle()
        XCTAssertTrue(m.isCold)
        XCTAssertNil(m.searchError, "the shelves have not failed at anything")
        XCTAssertNil(m.loadMoreError)
        XCTAssertFalse(m.loading)
        XCTAssertTrue(m.hits.isEmpty)
    }

    // MARK: Session id

    func testTheSessionIdFromPageOneRidesLaterPages() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish(FakeSearch.key("benchy"), hits: [1, 2], total: 10, session: "S1")
        await waitUntil({ m.hits.count == 2 })
        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await waitUntil({ m.loadingMore })
        var requests = await fake.requests
        for _ in 0..<2000 where requests.count < 2 { await Task.yield(); requests = await fake.requests }
        XCTAssertNil(requests[0].sessionId, "page one has none to send")
        XCTAssertEqual(requests[1].sessionId, "S1")
        XCTAssertEqual(requests[1].offset, 2)
    }

    // MARK: Load-more failure

    /// A 429 mid-scroll used to look exactly like the end of the results.
    func testAFailedPageIsReportedNotSwallowed() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish(FakeSearch.key("benchy"), hits: [1, 2], total: 10)
        await waitUntil({ m.hits.count == 2 })
        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await waitUntil({ m.loadingMore })
        await settle()
        await fake.fail(FakeSearch.key("benchy", offset: 2), MakerWorldSearchError(status: 429))
        await waitUntil({ m.loadMoreError != nil }, "the failure never surfaced")
        XCTAssertTrue(m.loadMoreError?.contains("rate-limit") ?? false)
        XCTAssertEqual(m.hits.count, 2, "the good content stays")
    }

    /// The catch needs the same write barrier as the success path: a stale page's failure must not
    /// land under a result set the user has since replaced. A slow "benchy" page two that 429s
    /// after the user has already searched "spool" must not put a rate-limit message under spool's
    /// results.
    func testAStaleLoadMoreFailureDoesNotOverwriteTheNewerSearch() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish(FakeSearch.key("benchy"), hits: [1, 2], total: 10)
        await waitUntil({ m.hits.count == 2 }, "the first page never landed")

        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await waitUntil({ m.loadingMore }, "the next page never started")
        m.search("spool")
        await settle()
        await fake.finish(FakeSearch.key("spool"), hits: [77], total: 1)
        await waitUntil({ m.hits.map(\.id) == [77] }, "the new search never landed")

        await fake.fail(FakeSearch.key("benchy", offset: 2), MakerWorldSearchError(status: 429))
        await settle()
        XCTAssertNil(m.loadMoreError, "a stale page's failure must not land under a different search")
    }

    /// The trailing tile that drives `loadMore` stays near the bottom of the grid after a failed
    /// page, so without an entry guard a 429 gets re-hit on every scroll frame rather than only
    /// when the user taps Retry. Retry clears `loadMoreError` before calling `loadMore` again.
    func testLoadMoreDoesNotReFireAfterAFailedPageUntilTheErrorIsCleared() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish(FakeSearch.key("benchy"), hits: [1, 2], total: 10)
        await waitUntil({ m.hits.count == 2 }, "the first page never landed")

        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await waitUntil({ m.loadingMore }, "the next page never started")
        await settle()
        await fake.fail(FakeSearch.key("benchy", offset: 2), MakerWorldSearchError(status: 429))
        await waitUntil({ m.loadMoreError != nil }, "the failure never surfaced")

        let afterFailure = await fake.callCount()
        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await settle()
        let afterReappear = await fake.callCount()
        XCTAssertEqual(afterReappear, afterFailure,
                       "a reappearing trailing tile must not re-hit a 429 the user has not retried")

        m.loadMoreError = nil
        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        // `loadingMore` flips synchronously inside `loadMore`, so waiting on it proves nothing
        // about whether the actor call underneath has actually run yet — poll the fake instead.
        var afterRetry = await fake.callCount()
        for _ in 0..<2000 where afterRetry < afterFailure + 1 {
            await Task.yield()
            afterRetry = await fake.callCount()
        }
        XCTAssertEqual(afterRetry, afterFailure + 1,
                       "clearing the error and calling loadMore again must issue the retry")
        await fake.finish(FakeSearch.key("benchy", offset: 2), hits: [3], total: 10)
    }

    // MARK: Cold start

    func testColdStartLoadsTrendingAndHotWordsOnce() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.loadColdStart()
        await settle()
        await fake.finish(FakeSearch.key(nil, sort: .trending), hits: [5, 6])
        await waitUntil({ m.trending.count == 2 })
        XCTAssertEqual(m.hotWords, ["halloween"])
        XCTAssertTrue(m.isCold, "loading the cold shelves is not a search")
        let before = await fake.callCount()
        m.loadColdStart()
        await settle()
        let after = await fake.callCount()
        XCTAssertEqual(after, before, "once per session")
    }

    func testSuggestionsFollowTheFieldAndClearOnSearch() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.query = "phone"
        m.suggest("phone")
        await waitUntil({ !m.suggestions.isEmpty })
        XCTAssertEqual(m.suggestions, ["phone holder", "phone case"])
        m.search("phone holder")
        XCTAssertTrue(m.suggestions.isEmpty, "submitting is the end of suggesting")
    }

    // MARK: Paging

    func testLoadMorePagesFromTheCurrentCountAndMergesRatherThanAppends() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish(FakeSearch.key("benchy"), hits: [1, 2], total: 10)
        await waitUntil({ m.hits.count == 2 }, "the first page never landed")

        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await waitUntil({ m.loadingMore }, "the next page never started")
        var requests = await fake.requests
        for _ in 0..<2000 where requests.count < 2 { await Task.yield(); requests = await fake.requests }
        XCTAssertEqual(requests.map(\.offset), [0, 2], "the next page starts where the loaded ones end")

        // Page two repeats id 2 — the endpoint's ordering is unstable, so this genuinely happens.
        await fake.finish(FakeSearch.key("benchy", offset: 2), hits: [2, 3], total: 10)
        await waitUntil({ m.hits.count == 3 }, "the second page never merged")
        XCTAssertEqual(m.hits.map(\.id), [1, 2, 3], "a repeated id must not become a duplicate row")
    }

    func testLoadMoreDoesNothingWithoutMoreToLoad() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish(FakeSearch.key("benchy"), hits: [1, 2], total: 2)
        await waitUntil({ m.hits.count == 2 }, "the page never landed")
        let before = await fake.callCount()
        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await settle()
        let after = await fake.callCount()
        XCTAssertEqual(after, before, "no request when the total is already loaded")
    }

    /// A page belonging to a result set that has since been replaced must be discarded, or switching
    /// category mid-page appends the old category's models to the new one's.
    func testAPageArrivingAfterTheResultSetChangedIsDiscarded() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish(FakeSearch.key("benchy"), hits: [1, 2], total: 10)
        await waitUntil({ m.hits.count == 2 }, "the first page never landed")

        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await waitUntil({ m.loadingMore }, "the next page never started")
        m.search("spool")
        await waitUntil({ m.activeQuery == "spool" })
        await fake.finish(FakeSearch.key("benchy", offset: 2), hits: [3, 4], total: 10)
        await fake.finish(FakeSearch.key("spool"), hits: [77], total: 1)
        await waitUntil({ m.hits.map(\.id) == [77] }, "the new search never landed")

        XCTAssertEqual(m.hits.map(\.id), [77], "the stale page must not join the new result set")
    }

    // MARK: Back into a folder list

    /// Going back to the folder list should be instant — the collections have not changed in the
    /// seconds since they loaded.
    func testBackToCollectionsDoesNotRefetchWhenTheListIsStillHeld() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.collections = [MakerWorldCollection(id: 1, title: "Prints", count: 3)]
        m.activeCollection = m.collections.first
        m.backToCollections(CollectionsClient(baseUrl: nil, apiKey: ""))
        XCTAssertTrue(m.showingCollections)
        XCTAssertNil(m.activeCollection)
        XCTAssertFalse(m.loading, "no request when the folder list is already in hand")
    }

    // MARK: Resolve cache

    func testResolveCacheMakesBackThenForwardInstant() {
        let m = ExploreModel(searchClient: FakeSearch())
        XCTAssertNil(m.cachedResolve(40146))
        let r = MakerWorldResolved(modelId: 40146, design: MWDesign(id: 40146), instances: [])
        m.cacheResolve(r, for: 40146)
        XCTAssertEqual(m.cachedResolve(40146)?.modelId, 40146)
        XCTAssertNil(m.cachedResolve(999), "a different model is a different answer")
    }
    // MARK: Leaving a mode

    /// The dead end this fixes, reported from the device: search "spool", tap "My collections", and
    /// the results are gone with the chip stuck on and the query still in the field.
    func testLeavingCollectionsRestoresTheSearchYouWereLookingAt() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        let collections = CollectionsClient(baseUrl: nil, apiKey: "")

        m.search("spool")
        await settle()
        await fake.finish(FakeSearch.key("spool"), hits: [1, 2, 3], total: 3)
        await waitUntil({ m.hits.count == 3 }, "the search never landed")

        m.openCollections(collections)
        await settle()
        XCTAssertTrue(m.showingCollections)
        XCTAssertTrue(m.canExitMode, "a mode you can enter must be one you can leave")

        m.exitMode()
        XCTAssertFalse(m.showingCollections)
        XCTAssertEqual(m.activeQuery, "spool")
        XCTAssertEqual(m.hits.map(\.id), [1, 2, 3], "restored, not refetched")
        let calls = await fake.callCount()
        XCTAssertEqual(calls, 1, "leaving a mode must not cost a round trip")
    }

    func testLeavingACategoryKeepsTheKeywordAndRefetches() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("spool")
        await settle()
        await fake.finish(FakeSearch.key("spool"), hits: [7], total: 1)
        await waitUntil({ m.hits.count == 1 })

        m.browse(MWNav(key: "category_700", name: "Tools"))
        await settle()
        await fake.finish(FakeSearch.key("spool", cat: 700), hits: [9], total: 1)
        await waitUntil({ m.hits.map(\.id) == [9] })

        m.exitMode()
        XCTAssertNil(m.activeNav)
        XCTAssertEqual(m.activeQuery, "spool")
        await settle()
        await fake.finish(FakeSearch.key("spool"), hits: [7], total: 1)
        await waitUntil({ m.hits.map(\.id) == [7] })
    }

    /// Entering a mode from the cold screen leaves nothing to restore, so exiting goes back to cold
    /// rather than to an empty grid that reads as "your search found nothing".
    func testLeavingAModeEnteredFromColdReturnsToCold() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.browse(MWNav(key: "Trending", name: "Trending"))
        await settle()
        await fake.finish(FakeSearch.key(nil, sort: .trending), hits: [1, 2], total: 2)
        await waitUntil({ m.hits.count == 2 })

        m.exitMode()
        XCTAssertTrue(m.isCold)
        XCTAssertTrue(m.hits.isEmpty)
        XCTAssertFalse(m.canExitMode, "nothing is on, so nothing offers to turn off")
    }

    /// Searching is itself a way out, and it must not leave a stale snapshot that a later chip tap
    /// would restore over the top of newer results.
    func testSearchingClearsWhatThereWasToGoBackTo() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("first")
        await settle()
        await fake.finish(FakeSearch.key("first"), hits: [1], total: 1)
        await waitUntil({ m.hits.count == 1 })

        m.openCollections(CollectionsClient(baseUrl: nil, apiKey: ""))
        await settle()
        m.search("second")
        await settle()
        await fake.finish(FakeSearch.key("second"), hits: [2], total: 1)
        await waitUntil({ m.hits.map(\.id) == [2] })

        m.exitMode()
        XCTAssertEqual(m.activeQuery, "second", "the newer search must survive")
        XCTAssertEqual(m.hits.map(\.id), [2])
    }

    /// A folder is a mode too — opening one and leaving must not strand you inside it.
    func testLeavingAnOpenFolderAlsoReturnsToTheSearch() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        let collections = CollectionsClient(baseUrl: nil, apiKey: "")
        m.search("spool")
        await settle()
        await fake.finish(FakeSearch.key("spool"), hits: [5], total: 1)
        await waitUntil({ m.hits.count == 1 })

        m.openCollections(collections)
        await settle()
        m.openCollection(MakerWorldCollection(id: 3, title: "Prints", count: 2), client: collections)
        await settle()
        XCTAssertTrue(m.canExitMode)

        m.exitMode()
        XCTAssertNil(m.activeCollection)
        XCTAssertEqual(m.activeQuery, "spool")
        XCTAssertEqual(m.hits.map(\.id), [5])
    }

}

import XCTest
@testable import Sprout

/// A search client the test drives by hand.
///
/// Each call parks on a continuation until the test releases it, which is the only way to get a
/// second request in flight while the first is still pending — and "two requests in flight" is
/// precisely the situation the old `guard !searching` got wrong.
private actor FakeSearch: MakerWorldSearching {
    struct Call: Sendable, Equatable { var kind: String; var arg: String; var offset: Int }

    private var pending: [String: CheckedContinuation<MWSearchPage, Error>] = [:]
    private(set) var calls: [Call] = []

    func search(_ keyword: String, offset: Int, limit: Int) async throws -> MWSearchPage {
        calls.append(Call(kind: "search", arg: keyword, offset: offset))
        return try await park("search:\(keyword)")
    }

    func browse(navKey: String, offset: Int, limit: Int) async throws -> MWSearchPage {
        calls.append(Call(kind: "browse", arg: navKey, offset: offset))
        return try await park("browse:\(navKey)")
    }

    func navs() async throws -> [MWNav] { [] }

    private func park(_ key: String) async throws -> MWSearchPage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in pending[key] = c }
        } onCancel: {
            Task { await self.fail(key, CancellationError()) }
        }
    }

    /// Let a parked call return.
    func finish(_ key: String, hits: [Int], total: Int? = nil) {
        pending.removeValue(forKey: key)?
            .resume(returning: MWSearchPage(total: total ?? hits.count,
                                            hits: hits.map { MWSearchHit(id: $0) }))
    }

    func fail(_ key: String, _ error: Error) {
        pending.removeValue(forKey: key)?.resume(throwing: error)
    }

    func isParked(_ key: String) -> Bool { pending[key] != nil }
    func callCount() -> Int { calls.count }
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
    /// while a search was in flight did *nothing at all*.
    func testTappingACategoryDuringASearchSwitchesToIt() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)

        m.search("benchy")
        await waitUntil({ m.loading }, "the search never started")
        var inFlight = false
        for _ in 0..<2000 where !inFlight { inFlight = await fake.isParked("search:benchy"); await Task.yield() }
        XCTAssertTrue(inFlight, "the search should be in flight")

        m.browse(MWNav(key: "Trending", name: "Trending"))
        await settle()

        let calls = await fake.calls
        XCTAssertEqual(calls.map(\.kind), ["search", "browse"], "the category tap must be served")
        XCTAssertEqual(m.activeNav, "Trending")
        XCTAssertNil(m.activeQuery, "the query it replaced must not still own the grid")
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
        await fake.finish("search:first", hits: [111])
        await fake.finish("search:second", hits: [222])
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
        await fake.finish("search:second", hits: [1])
        await settle()
        XCTAssertNil(m.searchError)
    }

    func testARealFailureIsReportedWithTheClientsOwnSentence() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.fail("search:benchy", SproutError("MakerWorld refused the request."))
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
        await fake.finish("search:first", hits: [1, 2, 3])
        await waitUntil({ m.hits.count == 3 }, "the first page never landed")
        XCTAssertEqual(m.hits.count, 3)

        m.search("second")
        await settle()
        XCTAssertEqual(m.hits.map(\.id), [1, 2, 3], "the grid must not flash empty mid-request")
        XCTAssertTrue(m.loading)

        await fake.finish("search:second", hits: [9])
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
        await fake.finish("search:first", hits: [1, 2])
        await waitUntil({ m.hits.count == 2 }, "the search never landed")

        m.openCollections(CollectionsClient(baseUrl: nil, apiKey: ""))
        await settle()
        XCTAssertTrue(m.hits.isEmpty)
        XCTAssertTrue(m.showingCollections)
    }

    // MARK: Sorting

    /// A sort carried into a new result set would reorder it before it was ever asked for.
    func testANewResultSetResetsTheSortToRelevance() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.sort = .downloads
        m.search("benchy")
        XCTAssertEqual(m.sort, .relevance, "the reset is synchronous — it must not wait on the network")
    }

    func testOrderedHitsAppliesTheSort() {
        let m = ExploreModel(searchClient: FakeSearch())
        var a = MWSearchHit(id: 1); a.downloadCount = 5
        var b = MWSearchHit(id: 2); b.downloadCount = 90
        m.hits = [a, b]
        XCTAssertEqual(m.orderedHits.map(\.id), [1, 2])
        m.sort = .downloads
        XCTAssertEqual(m.orderedHits.map(\.id), [2, 1])
    }

    // MARK: Paging

    func testLoadMorePagesFromTheCurrentCountAndMergesRatherThanAppends() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish("search:benchy", hits: [1, 2], total: 10)
        await waitUntil({ m.hits.count == 2 }, "the first page never landed")

        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await waitUntil({ m.loadingMore }, "the next page never started")
        var searchCalls = await fake.calls
        for _ in 0..<2000 where searchCalls.filter({ $0.kind == "search" }).count < 2 {
            await Task.yield(); searchCalls = await fake.calls
        }
        let offsets = searchCalls.filter { $0.kind == "search" }.map(\.offset)
        XCTAssertEqual(offsets, [0, 2], "the next page starts where the loaded ones end")

        // Page two repeats id 2 — the endpoint's ordering is unstable, so this genuinely happens.
        await fake.finish("search:benchy", hits: [2, 3], total: 10)
        await waitUntil({ m.hits.count == 3 }, "the second page never merged")
        XCTAssertEqual(m.hits.map(\.id), [1, 2, 3], "a repeated id must not become a duplicate row")
    }

    func testLoadMoreDoesNothingWithoutMoreToLoad() async throws {
        let fake = FakeSearch()
        let m = ExploreModel(searchClient: fake)
        m.search("benchy")
        await settle()
        await fake.finish("search:benchy", hits: [1, 2], total: 2)
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
        await fake.finish("search:benchy", hits: [1, 2], total: 10)
        await waitUntil({ m.hits.count == 2 }, "the first page never landed")

        m.loadMore(CollectionsClient(baseUrl: nil, apiKey: ""))
        await waitUntil({ m.loadingMore }, "the next page never started")
        m.browse(MWNav(key: "Trending", name: "Trending"))
        await waitUntil({ m.activeNav == "Trending" })
        await fake.finish("search:benchy", hits: [3, 4], total: 10)
        await fake.finish("browse:Trending", hits: [77], total: 1)
        await waitUntil({ m.hits.map(\.id) == [77] }, "the category never landed")

        XCTAssertEqual(m.hits.map(\.id), [77], "the stale page must not join the new category")
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
}

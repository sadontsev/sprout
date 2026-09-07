import XCTest
@testable import Sprout

/// Covers `Domain/MakerWorldSearch.swift` and the search wire types.
final class MakerWorldSearchTests: XCTestCase {

    /// Trimmed capture of `GET api.bambulab.com/v1/search-service/select/design2?keyword=phone+stand
    /// &orderBy=score&limit=2` (2026-09-07). `is_printable` is on the wire in snake case; the plain
    /// decoder cannot see it, and nothing may render it.
    private static let page = #"""
    {"total":4688,"searchSessionId":"eHfKH2iNCeYzfQISP9YSdTyYQxDG1sd92biwLi3RpwGB","hits":[
      {"id":1976503,"title":"THE BEST PHONE STAND","slug":"the-best-phone-stand",
       "cover":"https://makerworld.bblmw.com/makerworld/model/US4fb90c25038ae8/design/x.jpg",
       "likeCount":5161,"collectionCount":9000,"printCount":33609,"downloadCount":38246,
       "designCreator":{"uid":3001310494,"name":"Shelder","handle":"shelder","avatar":"https://a/b.jpg"},
       "createTime":"2025-11-09T00:00:00Z","nsfw":false,"isStaffPicked":true,"is_printable":true,
       "isExclusive":true,"license":"Standard Digital File License"},
      {"id":3047341,"title":"Benchy Keychain","cover":"https://makerworld.bblmw.com/c/3047341.jpg",
       "license":"BY","nsfw":true,"likeCount":9,"printCount":4,"downloadCount":1500,
       "designCreator":{"name":"someone"}}
    ],"suggest":[],"insertion":[]}
    """#

    private func decodePage() throws -> MWSearchPage {
        try JSONDecoder().decode(MWSearchPage.self, from: Data(Self.page.utf8))
    }

    // MARK: - Decoding

    /// This API is camelCase inside a camelCase envelope — the opposite of Bambuddy's. Decoding it
    /// with Bambuddy's `.convertFromSnakeCase` decoder would leave every count nil.
    func testHitsDecodeWithAPlainDecoder() throws {
        let p = try decodePage()
        XCTAssertEqual(p.total, 4688)
        XCTAssertEqual(p.searchSessionId, "eHfKH2iNCeYzfQISP9YSdTyYQxDG1sd92biwLi3RpwGB")
        XCTAssertEqual(p.hits?.count, 2)
        let first = try XCTUnwrap(p.hits?.first)
        XCTAssertEqual(first.id, 1976503)
        XCTAssertEqual(first.title, "THE BEST PHONE STAND")
        XCTAssertEqual(first.downloadCount, 38246)
        XCTAssertEqual(first.designCreator?.name, "Shelder")
        XCTAssertEqual(first.createTime, "2025-11-09T00:00:00Z")
        XCTAssertEqual(first.isStaffPicked, true)
        XCTAssertNil(p.hits?[1].isStaffPicked, "unstated is not false")
    }

    /// The endpoint that does NOT work announces itself this way, and it must decode rather than
    /// throw — otherwise a working-but-empty search is reported as a broken one.
    func testANullHitsListDecodesAsNoResultsNotAsAFailure() throws {
        let p = try JSONDecoder().decode(MWSearchPage.self,
                                         from: Data(#"{"total":0,"hits":null}"#.utf8))
        XCTAssertEqual(p.total, 0)
        XCTAssertNil(p.hits)
    }

    // MARK: - Intent: one field, two jobs

    func testAMakerWorldLinkResolvesRatherThanSearches() {
        XCTAssertEqual(MakerWorldSearch.intent(for: "https://makerworld.com/models/40146"),
                       .resolve(modelId: 40146))
        XCTAssertEqual(MakerWorldSearch.intent(for: "https://makerworld.com/en/models/1400373"),
                       .resolve(modelId: 1400373))
        XCTAssertEqual(MakerWorldSearch.intent(for: " https://makerworld.com/models/40146#profileId-9 "),
                       .resolve(modelId: 40146))
    }

    func testASlugAfterTheIdStillResolves() {
        XCTAssertEqual(MakerWorldSearch.intent(for: "https://makerworld.com/en/models/40146-benchy"),
                       .resolve(modelId: 40146))
    }

    func testABareModelIdIsTreatedAsALink() {
        XCTAssertEqual(MakerWorldSearch.intent(for: "1400373"), .resolve(modelId: 1400373))
    }

    /// A short number is a search term, not an id — "3" should find models called 3, not open model 3.
    func testAShortNumberIsSearchedForNotOpened() {
        XCTAssertEqual(MakerWorldSearch.intent(for: "3"), .search("3"))
        XCTAssertEqual(MakerWorldSearch.intent(for: "123"), .search("123"))
    }

    func testAnythingElseSearches() {
        XCTAssertEqual(MakerWorldSearch.intent(for: "benchy"), .search("benchy"))
        XCTAssertEqual(MakerWorldSearch.intent(for: "  cable clip  "), .search("cable clip"))
    }

    /// A link to somewhere else is searched for, not refused. The user never claimed it was a
    /// MakerWorld link, so "that isn't a MakerWorld link" would be answering a question nobody asked.
    func testALinkToAnotherSiteIsSearchedRatherThanRefused() {
        XCTAssertEqual(MakerWorldSearch.intent(for: "https://thingiverse.com/thing:763622"),
                       .search("https://thingiverse.com/thing:763622"))
    }

    func testAnEmptyFieldIsIdle() {
        XCTAssertEqual(MakerWorldSearch.intent(for: ""), .idle)
        XCTAssertEqual(MakerWorldSearch.intent(for: "   \n "), .idle)
    }

    func testTheButtonSaysWhatWillHappen() {
        XCTAssertEqual(MakerWorldSearch.intent(for: "benchy").buttonLabel, "Search")
        XCTAssertEqual(MakerWorldSearch.intent(for: "https://makerworld.com/models/1").buttonLabel, "Open")
        XCTAssertEqual(MakerWorldSearch.Intent.idle.buttonLabel, "Search")
    }

    func testModelUrlIsWhatResolveTakes() {
        XCTAssertEqual(MakerWorldSearch.modelUrl(id: 40146), "https://makerworld.com/models/40146")
    }

    // MARK: - What a tile may claim

    func testStatsAreBuiltOnlyFromCountsTheHitCarries() throws {
        let hits = try XCTUnwrap(decodePage().hits)
        XCTAssertEqual(MakerWorldSearch.stats(hits[0]), "38k downloads  ·  33k prints")
        XCTAssertEqual(MakerWorldSearch.stats(hits[1]), "1.5k downloads  ·  4 prints")
    }

    /// Zero is a real answer; absent is not zero.
    func testZeroIsShownButAnAbsentCountIsOmitted() {
        var hit = MWSearchHit(id: 1)
        hit.downloadCount = 0
        XCTAssertEqual(MakerWorldSearch.stats(hit), "0 downloads")

        hit.downloadCount = nil
        hit.likeCount = 5
        XCTAssertEqual(MakerWorldSearch.stats(hit), "5 likes", "falls back rather than inventing a 0")

        XCTAssertEqual(MakerWorldSearch.stats(MWSearchHit(id: 1)), "")
    }

    func testSingularAndPluralAgreeWithTheNumber() {
        var hit = MWSearchHit(id: 1)
        hit.downloadCount = 1
        XCTAssertEqual(MakerWorldSearch.stats(hit), "1 download")
    }

    func testCompactKeepsBigNumbersInsideATile() {
        XCTAssertEqual(MakerWorldSearch.compact(0), "0")
        XCTAssertEqual(MakerWorldSearch.compact(999), "999")
        XCTAssertEqual(MakerWorldSearch.compact(1_000), "1k")
        XCTAssertEqual(MakerWorldSearch.compact(1_500), "1.5k")
        XCTAssertEqual(MakerWorldSearch.compact(9_949), "9.9k")
        XCTAssertEqual(MakerWorldSearch.compact(48_000), "48k")
        XCTAssertEqual(MakerWorldSearch.compact(385_297), "385k")
        XCTAssertEqual(MakerWorldSearch.compact(1_300_000), "1.3M")
        XCTAssertEqual(MakerWorldSearch.compact(12_000_000), "12M")
    }

    func testTheLicenceChipMatchesTheDetailScreensRules() throws {
        let hits = try XCTUnwrap(decodePage().hits)
        XCTAssertEqual(MakerWorldSearch.licence(hits[0])?.label,
                       MWLicence(code: "Standard Digital File License").label)
        XCTAssertEqual(MakerWorldSearch.licence(hits[1])?.label, "CC BY")
        XCTAssertNil(MakerWorldSearch.licence(MWSearchHit(id: 1)))
    }

    func testAdultContentIsMarkedRatherThanHidden() throws {
        let hits = try XCTUnwrap(decodePage().hits)
        XCTAssertFalse(MakerWorldSearch.isAdult(hits[0]))
        XCTAssertTrue(MakerWorldSearch.isAdult(hits[1]))
        XCTAssertFalse(MakerWorldSearch.isAdult(MWSearchHit(id: 1)), "unstated is not true")
    }

    // MARK: - Paging

    func testHasMoreIsDrivenByTheReportedTotal() {
        XCTAssertTrue(MakerWorldSearch.hasMore(loaded: 20, total: 7076))
        XCTAssertFalse(MakerWorldSearch.hasMore(loaded: 7076, total: 7076))
        XCTAssertFalse(MakerWorldSearch.hasMore(loaded: 0, total: 0))
        XCTAssertFalse(MakerWorldSearch.hasMore(loaded: 20, total: nil))
    }

    /// An exact multiple of the page size is where "the last page was full" gets it wrong.
    func testAFullFinalPageDoesNotPromiseAnotherOne() {
        XCTAssertFalse(MakerWorldSearch.hasMore(loaded: 40, total: 40))
    }

    /// The endpoint's ordering is not stable between calls — the same query returned a different
    /// leading hit seconds apart — so offset paging genuinely repeats models.
    func testMergeDropsHitsAlreadyOnScreen() {
        let a = [MWSearchHit(id: 1), MWSearchHit(id: 2)]
        let b = [MWSearchHit(id: 2), MWSearchHit(id: 3)]
        XCTAssertEqual(MakerWorldSearch.merge(a, b).map(\.id), [1, 2, 3])
    }

    func testMergeKeepsOrderAndSurvivesAnEmptyPage() {
        let a = [MWSearchHit(id: 5), MWSearchHit(id: 1)]
        XCTAssertEqual(MakerWorldSearch.merge(a, []).map(\.id), [5, 1])
        XCTAssertEqual(MakerWorldSearch.merge([], a).map(\.id), [5, 1])
    }

    func testMergeDedupesWithinASinglePageToo() {
        XCTAssertEqual(MakerWorldSearch.merge([], [MWSearchHit(id: 7), MWSearchHit(id: 7)]).map(\.id),
                       [7])
    }

    // MARK: - Browse

    func testPersonalisedAndUnsupportedCategoriesAreDropped() {
        let navs = [MWNav(key: "Following", name: "Following"),
                    MWNav(key: "Foryou", name: "For You"),
                    MWNav(key: "Trending", name: "Trending"),
                    MWNav(key: "category_400", name: "Household"),
                    MWNav(key: "Crowdfunding", name: "Crowdfunding"),
                    MWNav(key: "LaserCut", name: "Laser & Cut")]
        // LaserCut needs a `designType` the probes never settled; a chip that lists 3D models
        // under a laser heading would be a lie. `Crowdfunding` is the case the old BLOCKLIST could
        // not see: a key nobody had heard of when it was written became a chip whose only effect
        // was to drop the keyword and browse everything, because `categoryId(navKey:)` is nil for
        // it. The filter is an allowlist now — a nav is kept only if we know what request it makes.
        XCTAssertEqual(MakerWorldSearch.browsable(navs).map(\.key), ["Trending", "category_400"])
    }

    func testAKeylessCategoryIsDroppedRatherThanRenderedAsADeadChip() {
        XCTAssertEqual(MakerWorldSearch.browsable([MWNav(key: "", name: "Mystery")]).count, 0)
    }

    // MARK: - A printer filter that has gone stale

    /// `printerCode` is written once and never re-read, so it outlives the printer it names.
    func testAPrinterFilterIsDroppedWhenItNamesADifferentPrinter() {
        var f = MWSearchFilters()
        f.printerCode = "O1C2"
        f.customisable = true

        XCTAssertEqual(f.reconciled(printerCode: "O1C2").printerCode, "O1C2",
                       "the same printer is still the user's printer")
        XCTAssertNil(f.reconciled(printerCode: "N2S").printerCode,
                     "a filter for the machine you no longer have is off, not silently applied")
        XCTAssertNil(f.reconciled(printerCode: nil).printerCode,
                     "no printer connected means no code to filter by")
        XCTAssertTrue(f.reconciled(printerCode: nil).customisable,
                      "only the printer is reconciled — the rest of the sheet is the user's")
        XCTAssertTrue(MWSearchFilters().reconciled(printerCode: nil).isEmpty)
    }

    // MARK: - Failure copy

    /// Every message keeps the paste path alive, because that is the one that does not depend on an
    /// undocumented endpoint.
    func testEverySearchFailureStillPointsAtThePastePath() {
        for status in [0, 401, 403, 418, 429, 500, -1] {
            let message = try! XCTUnwrap(MakerWorldSearchError(status: status).errorDescription)
            XCTAssertTrue(message.lowercased().contains("link"),
                          "status \(status) left the user with no way forward: \(message)")
        }
    }

    /// If MakerWorld ever gates these endpoints, search is removed — not worked around with a token
    /// the app must never hold.
    func testBeingGatedIsReportedAsAnEndingNotATransientError() {
        for status in [401, 403] {
            let message = try! XCTUnwrap(MakerWorldSearchError(status: status).errorDescription)
            XCTAssertTrue(message.contains("sign-in"))
            XCTAssertFalse(message.lowercased().contains("try again"))
        }
    }

    func testRateLimitingAndCaptchaAreNamedSeparately() {
        XCTAssertTrue(try XCTUnwrap(MakerWorldSearchError(status: 429).errorDescription).contains("rate-limit"))
        XCTAssertTrue(try XCTUnwrap(MakerWorldSearchError(status: 418).errorDescription).contains("CAPTCHA"))
    }
    // MARK: - Request vocabulary

    /// Measured 2026-09-07 against `select/design2`: each value changes the row set. The raw value
    /// IS the wire value, so a renamed case cannot drift from what the server accepts.
    func testSortWireValuesAreTheOnesTheServerHonours() {
        XCTAssertEqual(MakerWorldSearch.Sort.relevance.rawValue, "score")
        XCTAssertEqual(MakerWorldSearch.Sort.trending.rawValue, "hotScore")
        XCTAssertEqual(MakerWorldSearch.Sort.newest.rawValue, "newUploads")
        XCTAssertEqual(MakerWorldSearch.Sort.downloads.rawValue, "downloadCount")
        XCTAssertEqual(MakerWorldSearch.Sort.likes.rawValue, "likeCount")
        XCTAssertEqual(MakerWorldSearch.Sort.boosts.rawValue, "boosts")
        XCTAssertEqual(MakerWorldSearch.Sort.relevance.label, "Relevance")
        XCTAssertEqual(MakerWorldSearch.Sort.allCases.first, .relevance)
    }

    func testAnEmptyRequestAsksForModelsByRelevance() {
        let items = MWSearchRequest().queryItems
        XCTAssertEqual(items.map(\.0), ["designType", "orderBy", "limit", "offset"])
        XCTAssertEqual(items.map(\.1), ["0", "score", "50", "0"])
    }

    func testKeywordCategoryAndSessionTakeTheirPlaces() {
        var r = MWSearchRequest()
        r.keyword = "phone stand"
        r.categoryId = 700
        r.sort = .downloads
        r.offset = 50
        r.sessionId = "abc"
        let items = r.queryItems
        XCTAssertEqual(items.map(\.0),
                       ["designType", "keyword", "categories", "orderBy", "limit", "offset", "searchSessionId"])
        XCTAssertEqual(items[1].1, "phone stand", "encoding is the client's job, not the request's")
        XCTAssertEqual(items[2].1, "700")
        XCTAssertEqual(items[3].1, "downloadCount")
        XCTAssertEqual(items[6].1, "abc")
    }

    /// One test per filter, each pinned to the parameter name and value shape the site sends.
    func testEachFilterEmitsItsOwnParameter() {
        var f = MWSearchFilters()
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.queryItems.count, 0)

        f.printerCode = "O1C2"
        XCTAssertEqual(f.queryItems.last?.0, "devModelNames")
        XCTAssertEqual(f.queryItems.last?.1, "O1C2")

        f = MWSearchFilters(); f.nozzle = "0.4"
        XCTAssertEqual(f.queryItems.first?.0, "nozzleDiameters")
        XCTAssertEqual(f.queryItems.first?.1, "0.4")

        f = MWSearchFilters(); f.colours = .multi
        XCTAssertEqual(f.queryItems.first?.0, "multiColor")
        XCTAssertEqual(f.queryItems.first?.1, "true")
        f.colours = .single
        XCTAssertEqual(f.queryItems.first?.1, "false")

        f = MWSearchFilters(); f.maxMinutes = 180
        XCTAssertEqual(f.queryItems.first?.0, "print_duration")
        XCTAssertEqual(f.queryItems.first?.1, "1,180")

        f = MWSearchFilters(); f.maxGrams = 200
        XCTAssertEqual(f.queryItems.first?.0, "total_weight")
        XCTAssertEqual(f.queryItems.first?.1, "1,200")

        f = MWSearchFilters(); f.licences = ["BY-SA", "CC0"]
        XCTAssertEqual(f.queryItems.first?.0, "licenses")
        XCTAssertEqual(f.queryItems.first?.1, "BY-SA,CC0", "sorted, so the URL is stable")

        f = MWSearchFilters(); f.tag = .featured
        XCTAssertEqual(f.queryItems.first?.0, "model_tag")
        XCTAssertEqual(f.queryItems.first?.1, "featured")
        f.tag = .exclusive
        XCTAssertEqual(f.queryItems.first?.1, "exclusive")

        f = MWSearchFilters(); f.customisable = true
        XCTAssertEqual(f.queryItems.first?.0, "customizable")
        XCTAssertEqual(f.queryItems.first?.1, "true")
    }

    func testActiveCountIsTheBadgeNumber() {
        var f = MWSearchFilters()
        f.printerCode = "O1C2"
        f.nozzle = "0.4"
        f.licences = ["CC0"]
        XCTAssertEqual(f.activeCount, 3)
        XCTAssertFalse(f.isEmpty)
    }

    func testFiltersRideTheRequest() {
        var r = MWSearchRequest()
        r.filters.customisable = true
        XCTAssertTrue(r.queryItems.contains { $0.0 == "customizable" && $0.1 == "true" })
    }

    /// The H2C's MakerWorld code is `O1C2`, measured on `design-service/design/{id}` compatibility
    /// lists. An unknown model gets nil, so the filter can dim itself rather than send a guess.
    func testPrinterCodesForTheModelsMakerWorldKnows() {
        XCTAssertEqual(MWPrinterCode.code(forModel: "H2C"), "O1C2")
        XCTAssertEqual(MWPrinterCode.code(forModel: "h2c"), "O1C2")
        XCTAssertEqual(MWPrinterCode.code(forModel: "A1"), "N2S")
        XCTAssertEqual(MWPrinterCode.code(forModel: "A1 mini"), "N1")
        XCTAssertEqual(MWPrinterCode.code(forModel: "X1 Carbon"), "BL-P001")
        XCTAssertEqual(MWPrinterCode.code(forModel: "X1C"), "BL-P001")
        XCTAssertNil(MWPrinterCode.code(forModel: "K2 Plus"))
        XCTAssertNil(MWPrinterCode.code(forModel: nil))
    }

    func testCategoryIdComesFromTheNavKey() {
        XCTAssertEqual(MakerWorldSearch.categoryId(navKey: "category_400"), 400)
        XCTAssertNil(MakerWorldSearch.categoryId(navKey: "Trending"))
        XCTAssertNil(MakerWorldSearch.categoryId(navKey: nil))
        XCTAssertNil(MakerWorldSearch.categoryId(navKey: "category_"))
    }

    // MARK: - URL building

    func testTheClientBuildsOneDesign2URL() {
        var r = MWSearchRequest()
        r.keyword = "phone stand"
        r.filters.licences = ["CC0", "BY-SA"]
        let url = MakerWorldSearchClient.url(for: r)
        XCTAssertEqual(url.absoluteString,
                       "https://api.bambulab.com/v1/search-service/select/design2?designType=0"
                       + "&keyword=phone%20stand&orderBy=score&licenses=BY%2DSA%2CCC0&limit=50&offset=0")
    }

    func testSuggestionsDecodeFromThePopularList() throws {
        let body = #"{"popular":[{"option":"phone stand","highlighted":"<em>phone</em> stand"},{"option":"headphone stand"}],"design":[],"user":[]}"#
        XCTAssertEqual(try MakerWorldSearchClient.suggestions(from: Data(body.utf8)),
                       ["phone stand", "headphone stand"])
    }

    func testHotWordsDecodeFromTheHotList() throws {
        let body = #"{"hotList":{"name":"","topWords":[],"listWords":["halloween","clicker"]},"customList":[]}"#
        XCTAssertEqual(try MakerWorldSearchClient.hotWords(from: Data(body.utf8)), ["halloween", "clicker"])
    }

    // MARK: Descriptions

    func testProfileBlurbIsReducedToPlainText() {
        // The exact shape MakerWorld returned for a live profile.
        XCTAssertEqual(MakerWorldSearch.plainText("<p>0.2mm layer, 2 walls, 15% infill</p>"),
                       "0.2mm layer, 2 walls, 15% infill")
        XCTAssertEqual(MakerWorldSearch.plainText("<p>One</p><p>Two</p>"), "One\nTwo")
        XCTAssertEqual(MakerWorldSearch.plainText("Bambu &amp; friends &lt;3"), "Bambu & friends <3")
        XCTAssertEqual(MakerWorldSearch.plainText("<b>Bold</b> and <i>italic</i>"), "Bold and italic")
    }

    /// A blurb that is only markup is the same as no blurb, and the preview must not reserve space
    /// for an empty paragraph.
    func testEmptyBlurbsBecomeNil() {
        XCTAssertNil(MakerWorldSearch.plainText(nil))
        XCTAssertNil(MakerWorldSearch.plainText(""))
        XCTAssertNil(MakerWorldSearch.plainText("<p></p>"))
        XCTAssertNil(MakerWorldSearch.plainText("<p>   </p><br/>"))
    }

    // MARK: Which language is shown

    /// **`summaryTranslated` is an EMPTY STRING when there is no translation, not null** — measured
    /// on live data. A plain `nil` check selects the empty one and renders a blank description,
    /// which is the same present-but-empty trap this API sprang with `total: 0` meaning "not
    /// authenticated".
    func testAnEmptyTranslationFallsBackToTheOriginal() {
        let d = MakerWorldSearch.description(original: "<p>原文</p>", translated: "")
        XCTAssertEqual(d?.html, "<p>原文</p>")
        XCTAssertEqual(d?.isTranslated, false)
    }

    func testTheTranslationIsPreferredWhenThereIsOne() {
        let d = MakerWorldSearch.description(original: "<p>本配件兼容 H2D</p>",
                                             translated: "<p>Compatible with H2D</p>")
        XCTAssertEqual(d?.html, "<p>Compatible with H2D</p>")
        XCTAssertEqual(d?.isTranslated, true, "the UI says whose words these are")
    }

    /// Emptiness is judged after the markup is stripped: `<p></p>` and a lone `<figure>` are
    /// present-but-empty in exactly the same way as "".
    func testATranslationOfNothingButMarkupIsNotATranslation() {
        let d = MakerWorldSearch.description(original: "<p>原文</p>", translated: "<p></p><figure></figure>")
        XCTAssertEqual(d?.html, "<p>原文</p>")
        XCTAssertEqual(d?.isTranslated, false)
    }

    func testNoDescriptionAtAllIsNil() {
        XCTAssertNil(MakerWorldSearch.description(original: nil, translated: nil))
        XCTAssertNil(MakerWorldSearch.description(original: "", translated: ""))
        XCTAssertNil(MakerWorldSearch.description(original: "<p> </p>", translated: nil))
    }

    /// The boost widget is MakerWorld's donation UI. Its TITLE is a button label ("Boost Me"), which
    /// is not something the uploader wrote about their model; its CONTENT is their actual sentence.
    func testTheBoostWidgetsLabelIsDroppedButItsMessageIsKept() {
        let html = "<boostme><boosttitle>Boost Me</boosttitle>"
                 + "<boostcontent>New to modeling, thanks for your support~</boostcontent></boostme>"
                 + "<p>September 1, 2025</p>"
        XCTAssertEqual(MakerWorldSearch.markdown(fromHTML: html),
                       "New to modeling, thanks for your support~\n\nSeptember 1, 2025")
    }

    /// An embedded video cannot play inside a Text, but dropping it silently loses content the
    /// uploader added.
    func testAnEmbeddedVideoBecomesALink() {
        let out = MakerWorldSearch.markdown(
            fromHTML: "<figure class=\"media\"><oembed url=\"https://www.bilibili.com/video/BV1f\"></oembed></figure>")
        XCTAssertEqual(out, "[Video](https://www.bilibili.com/video/BV1f)")
    }

    /// The real Chinese description from the user's report, reduced to what the screen shows.
    func testARealTranslatedDescription() {
        let translated = "<boostme><boosttitle>Boost Me</boosttitle><boostcontent>New to modeling~</boostcontent></boostme>"
            + "<p>September 1, 2025</p>"
            + "<h2><span style=\"color: #E14747\"><strong><u>Compatible with H2D and H2S</u></strong></span></h2>"
            + "<p>&nbsp;</p><p>Use 3x20 screws</p>"
        let d = MakerWorldSearch.description(original: "<p>中文</p>", translated: translated)
        XCTAssertEqual(d?.isTranslated, true)
        XCTAssertEqual(MakerWorldSearch.markdown(fromHTML: d!.html),
                       "New to modeling~\n\nSeptember 1, 2025\n\n**Compatible with H2D and H2S**\n\nUse 3x20 screws")
    }

    // MARK: Rich descriptions

    private func md(_ html: String) -> String? { MakerWorldSearch.markdown(fromHTML: html) }

    func testEmphasisAndHeadingsSurvive() {
        XCTAssertEqual(md("<p>A <strong>bold</strong> claim</p>"), "A **bold** claim")
        XCTAssertEqual(md("<p>An <i>aside</i></p>"), "An *aside*")
        XCTAssertEqual(md("<h2>Title</h2><p>Body</p>"), "**Title**\n\nBody",
                       "a heading becomes bold on its own line — inline markdown cannot render #")
    }

    func testListsBecomeReadableLines() {
        XCTAssertEqual(md("<ul><li>one</li><li>two</li></ul>"), "• one\n• two")
        XCTAssertEqual(md("<ol><li>first</li><li>second</li></ol>"), "1. first\n2. second",
                       "an ordered list must count, or the steps lose their order")
    }

    /// The bug this prevents: uploader text is not markup. A description reading `2 * 3 * 4` would
    /// otherwise render "3" in italics, and `[see notes]` would become a broken link.
    func testUploaderTextIsEscapedSoItCannotBecomeMarkup() {
        XCTAssertEqual(md("<p>2 * 3 * 4</p>"), "2 \\* 3 \\* 4")
        XCTAssertEqual(md("<p>[see notes]</p>"), "\\[see notes\\]")
        XCTAssertEqual(md("<p>snake_case_name</p>"), "snake\\_case\\_name")
    }

    func testLinksKeepTheirTextAndTarget() {
        XCTAssertEqual(md("<p>See <a href=\"https://example.com/x\">the guide</a></p>"),
                       "See [the guide](https://example.com/x)")
    }

    /// A description is uploader-supplied, so a `javascript:` href must never become a tappable link.
    /// The words survive; the URL does not.
    func testOnlyHttpLinksAreEmitted() {
        XCTAssertEqual(md("<a href=\"javascript:alert(1)\">tap</a>"), "tap")
        XCTAssertEqual(md("<a href=\"data:text/html,x\">tap</a>"), "tap")
        XCTAssertEqual(md("<a href=\"/relative/path\">tap</a>"), "tap")
    }

    /// Parentheses would close the markdown link target early and spill the rest of the URL into the
    /// visible text.
    func testALinkWithParenthesesKeepsItsTextAndDropsTheTarget() {
        XCTAssertEqual(md("<a href=\"https://e.com/a(b)\">tap</a>"), "tap")
    }

    func testImagesAndUnknownTagsDoNotLeakMarkup() {
        XCTAssertEqual(md("<p>Before<img src=\"https://e.com/a.png\">After</p>"), "BeforeAfter")
        // MakerWorld ships custom elements; their contents are kept and the tags dropped. (The one
        // exception is `boosttitle`, which is a UI label — see the boost-widget test.)
        XCTAssertEqual(md("<lac-info><lac-badge>Kept</lac-badge></lac-info>"), "Kept")
    }

    func testEntitiesAreDecodedBeforeEscaping() {
        XCTAssertEqual(md("<p>Bambu &amp; friends &ndash; done</p>"), "Bambu & friends – done")
    }

    func testBlankRunsCollapseAndEmptyMarkupIsNil() {
        // Paragraphs keep ONE blank line between them — that is how the source reads and how it
        // should render. Runs of empty markup collapse to that, they do not accumulate.
        XCTAssertEqual(md("<p>One</p><p></p><p>Two</p>"), "One\n\nTwo")
        XCTAssertNil(md("<p></p><br><figure></figure>"))
        XCTAssertNil(MakerWorldSearch.markdown(fromHTML: nil))
        XCTAssertNil(MakerWorldSearch.markdown(fromHTML: ""))
    }

    /// Malformed input is a thing MakerWorld sends, not a thing to crash on.
    func testAnUnclosedTagIsSurvivable() {
        XCTAssertEqual(md("<p>Good text</p><p>trailing"), "Good text\n\ntrailing")
        XCTAssertNotNil(md("<p>text</p><strong"))
    }

    /// Shipped visibly and caught on screen: `**1. ****Seed Starter Tray 9 Cells **` with literal
    /// asterisks in the middle of the description.
    ///
    /// Markdown emphasis delimiters may not touch whitespace — `**text **` is not emphasis, it is
    /// the characters `**`. MakerWorld's spans routinely carry a trailing space, so the whitespace
    /// has to move outside the delimiters.
    func testEmphasisWithSurroundingSpaceStillParses() {
        XCTAssertEqual(md("<p><strong>Seed Sower : </strong>Offers three sizes</p>"),
                       "**Seed Sower :** Offers three sizes")
        XCTAssertEqual(md("<p>Available in <strong> 6-cell </strong>versions</p>"),
                       "Available in **6-cell** versions")
    }

    /// `<i> </i>` between words is real MakerWorld output. It used to emit a stray `* *`.
    func testAWhitespaceOnlySpanEmitsNoDelimiters() {
        XCTAssertEqual(md("<p>an<i> </i>Asanoha pattern</p>"), "an Asanoha pattern")
        XCTAssertEqual(md("<p>a<strong></strong>b"), "ab")
    }

    /// A bold list item must not stack its delimiters against the bullet.
    func testABoldListItemKeepsItsNumberOutsideTheEmphasis() {
        XCTAssertEqual(md("<ol><li><strong>Tray 9 Cells </strong></li></ol>"), "1. **Tray 9 Cells**")
    }

    /// Malformed nesting is input, not a crash — the words survive even when the formatting cannot.
    func testUnclosedEmphasisStillYieldsItsText() {
        XCTAssertEqual(md("<p>start <strong>bold text"), "start bold text")
        XCTAssertEqual(md("<p><em>a<strong>b</strong>"), "a**b**")
    }

    /// The real shape, from model 1400373.
    func testARealMakerWorldDescription() {
        let html = "<h2>Self-Watering Seed Starter</h2><p><strong>Designed for minimalist growers.</strong></p>"
                 + "<p>This <strong>modular kit</strong> features a base.<br><br>It also has an<i> </i>Asanoha pattern.</p>"
        let out = md(html)
        // `<i> </i>` between words contributes a space, not an empty emphasis.
        XCTAssertEqual(out, "**Self-Watering Seed Starter**\n\n**Designed for minimalist growers.**\n\n"
                          + "This **modular kit** features a base.\n\nIt also has an Asanoha pattern.")
    }
}

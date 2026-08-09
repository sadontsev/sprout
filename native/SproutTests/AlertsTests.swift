import XCTest
@testable import Sprout

// MARK: - Fixtures

private let okCaps = AlertCaps(connected: true, canControl: true)

/// A live, healthy print. Named in full because a bare `status` would be shadowed by anything
/// XCTestCase happens to declare.
private func printerStatus(_ mutate: (inout PrinterStatus) -> Void = { _ in }) -> PrinterStatus {
    var s = PrinterStatus()
    s.connected = true
    s.state = "RUNNING"
    mutate(&s)
    return s
}

/// A transport that fails every request, so the store's offline path can be exercised without a
/// network — and without a networked machine accidentally downloading Bambu's real feed mid-test.
private final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// A transport standing in for both Bambu hosts: the code feed, and a wiki page for any code.
private final class CannedBambuProtocol: URLProtocol {
    static let feed = Data(#"""
    {"data":{"device_hms":{"ver":1,"en":[{"ecode":"0501040000030002","intro":"Threaded rods need lubrication now."}]}}}
    """#.utf8)

    static let wikiPage = Data(#"""
    <html><head><meta property="og:title" content="HMS_0C00-0100-0002-0017: Nozzle camera lens is dirty." /></head></html>
    """#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = (url.host() ?? "").hasPrefix("wiki") ? Self.wikiPage : Self.feed
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession(_ protocolClass: AnyClass) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [protocolClass]
    return URLSession(configuration: config)
}

/// A scratch directory for one store's cache file.
private func scratchDirectory() throws -> URL {
    let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The live H2C notice, verbatim.
private func notice(severity: LooseNumber? = 5, fullCode: String? = "0500050000010007") -> HmsError {
    HmsError(code: "0x10007", module: 5, severity: severity, fullCode: fullCode)
}

private func ids(_ s: PrinterStatus?, _ caps: AlertCaps = okCaps) -> [String] {
    Alerts.present(s, caps: caps).map(\.id)
}

private func actionIds(_ s: PrinterStatus?, _ id: String, _ caps: AlertCaps = okCaps) -> [AlertActionId] {
    Alerts.present(s, caps: caps).first { $0.id == id }?.actions.map(\.id) ?? []
}

private func firstHms(_ alerts: [AlertVM]) -> AlertVM? {
    alerts.first { $0.id.hasPrefix("hms-") }
}

private func lookupURLs(_ alert: AlertVM?) -> [String] {
    alert?.actions.first { $0.id == .lookup }?.urls ?? []
}

final class AlertsTests: XCTestCase {

    func testAHealthyPrintRaisesNothing() {
        XCTAssertEqual(Alerts.present(printerStatus(), caps: okCaps), [])
        XCTAssertEqual(Alerts.present(nil, caps: okCaps), [])
    }

    // MARK: - Actions are offered only when the state actually allows them

    func testResumeAppearsWhenPausedAndNotWhilePrintingNormally() {
        XCTAssertEqual(actionIds(printerStatus { $0.state = "PAUSE" }, "paused"), [.resume, .stop])
        XCTAssertFalse(ids(printerStatus()).contains("paused"))
    }

    func testPausedIsRecognisedInEitherSpellingAndAnyCase() {
        XCTAssertTrue(ids(printerStatus { $0.state = "paused" }).contains("paused"))
        XCTAssertTrue(ids(printerStatus { $0.state = "Pause" }).contains("paused"))
    }

    func testPlateConfirmationAppearsOnlyWhileTheQueueIsActuallyWaiting() {
        XCTAssertEqual(actionIds(printerStatus { $0.awaitingPlateClear = true }, "plate"), [.plateCleared])
        XCTAssertFalse(ids(printerStatus { $0.awaitingPlateClear = false }).contains("plate"))
        // Absent is not the same as false, but it is treated the same way: no confirmation to give.
        XCTAssertFalse(ids(printerStatus()).contains("plate"))
    }

    func testAnOfflinePrinterShowsTheProblemButOffersNoControlItCannotPerform() {
        let offline = AlertCaps(connected: false, canControl: true)
        XCTAssertEqual(actionIds(printerStatus { $0.state = "PAUSE" }, "paused", offline), [])
        // Still explains the situation.
        XCTAssertTrue(ids(printerStatus { $0.state = "PAUSE" }, offline).contains("paused"))
    }

    func testWithoutControlPermissionNothingActionableIsOffered() {
        let readOnly = AlertCaps(connected: true, canControl: false)
        XCTAssertEqual(actionIds(printerStatus { $0.awaitingPlateClear = true }, "plate", readOnly), [])
    }

    func testStopIsAlwaysMarkedDestructiveSoTheUICanConfirmIt() {
        let actions = Alerts.present(printerStatus { $0.state = "PAUSE" }, caps: okCaps)[0].actions
        XCTAssertEqual(actions.first { $0.id == .stop }?.destructive, true)
        // Routine — no confirmation.
        XCTAssertEqual(actions.first { $0.id == .resume }?.destructive, false)
    }

    // MARK: - HMS notices

    func testDisplaysTheDashedCodeButLinksTheWikisUnderscorePath() throws {
        let a = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice()] }, caps: okCaps)))
        XCTAssertEqual(a.code, "0500-0500-0001-0007")
        let urls = lookupURLs(a)
        // The separator is what mattered: the dashed form 404s everywhere.
        XCTAssertEqual(urls.first?.split(separator: "/").last.map(String.init), "0500_0500_0001_0007")
        // Guaranteed-to-exist last resort.
        XCTAssertTrue(try XCTUnwrap(urls.last).contains("/hms/error-code"))
    }

    func testPutsThisMachinesWikiFamilyFirst() throws {
        // Verified live: 0C00_0100_0002_0017 is 200 under /h2/ and 404 under /x1/; the reverse for
        // 0300_0D00_0001_0003. So the model decides which page to try first.
        let h2 = Alerts.present(printerStatus { $0.hmsErrors = [notice()] }, caps: AlertCaps(connected: true, canControl: true, model: "H2C"))
        XCTAssertTrue(try XCTUnwrap(lookupURLs(firstHms(h2)).first).contains("/en/h2/"))
        let x1 = Alerts.present(printerStatus { $0.hmsErrors = [notice()] }, caps: AlertCaps(connected: true, canControl: true, model: "X1C"))
        XCTAssertTrue(try XCTUnwrap(lookupURLs(firstHms(x1)).first).contains("/en/x1/"))
    }

    func testStillOffersEveryOtherFamilyAsAFallback() throws {
        let list = Alerts.present(printerStatus { $0.hmsErrors = [notice()] }, caps: AlertCaps(connected: true, canControl: true, model: "H2C"))
        let urls = lookupURLs(firstHms(list))
        // h2, x1, p1, a1 — a mis-modelled printer still finds the page.
        XCTAssertEqual(urls.filter { $0.contains("/troubleshooting/") }.count, 4)
        XCTAssertTrue(try XCTUnwrap(urls.first).contains("/en/h2/"))
        XCTAssertEqual(urls.count, 5)
    }

    func testAnUnrecognisedSeverityStaysANeutralNotice() throws {
        let a = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice(severity: 5)] }, caps: okCaps)))
        XCTAssertEqual(a.title, "Printer notice")
        XCTAssertEqual(a.level, .warning)
    }

    func testMapsTheDocumentedSeverities() throws {
        func rung(_ severity: LooseNumber?) throws -> AlertVM {
            try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice(severity: severity)] }, caps: okCaps)))
        }
        XCTAssertEqual(try rung(1).level, .error)
        XCTAssertEqual(try rung(1).title, "Fatal notice")
        XCTAssertEqual(try rung(2).level, .error)
        XCTAssertEqual(try rung(2).title, "Serious notice")
        XCTAssertEqual(try rung(3).level, .warning)
        XCTAssertEqual(try rung(3).title, "Common notice")
        XCTAssertEqual(try rung(4).level, .info)
        XCTAssertEqual(try rung(4).title, "Info notice")
        // No severity at all is not a rung either.
        XCTAssertEqual(try rung(nil).title, "Printer notice")
    }

    func testOffersOneDismissForTheWholeBatchNotOnePerRow() {
        let list = Alerts.present(
            printerStatus { $0.hmsErrors = [notice(), notice(fullCode: "0500050000010008")] },
            caps: okCaps
        )
        let dismissals = list.flatMap(\.actions).filter { $0.id == .clearHms }
        XCTAssertEqual(dismissals.count, 1)
        XCTAssertEqual(dismissals.first?.label, "Dismiss all (2)")
    }

    func testASingleNoticeGetsThePlainDismissLabel() {
        let list = Alerts.present(printerStatus { $0.hmsErrors = [notice()] }, caps: okCaps)
        XCTAssertEqual(list.flatMap(\.actions).first { $0.id == .clearHms }?.label, "Dismiss")
    }

    func testARoutineNoticeNeverClaimsThePrintFailed() throws {
        let a = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice(severity: 4)] }, caps: okCaps)))
        XCTAssertTrue(a.detail.lowercased().contains("keeps going"))
        XCTAssertFalse(ids(printerStatus { $0.hmsErrors = [notice()] }).contains("print-error"))
    }

    func testAFatalNoticeDoesNotReassureThatThePrinterKeepsGoing() throws {
        let a = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice(severity: 1)] }, caps: okCaps)))
        XCTAssertFalse(a.detail.lowercased().contains("keeps going"))
        XCTAssertFalse(a.detail.lowercased().contains("keeps printing"))
        XCTAssertTrue(a.detail.lowercased().contains("serious"))
    }

    func testIdsAreStableAcrossPollsSoTheListDoesNotChurnMidPrint() {
        let s = printerStatus { $0.hmsErrors = [notice()] }
        XCTAssertEqual(ids(s), ids(s))
        XCTAssertEqual(ids(s), ["hms-0500-0500-0001-0007"])
    }

    // MARK: - Print errors

    func testARealPrintErrorLeadsTheListAndOffersResumeOrStop() {
        let list = Alerts.present(
            printerStatus {
                $0.printError = 84_033_543
                $0.state = "FAILED"
                $0.hmsErrors = [HmsError(fullCode: "0500050000010007")]
            },
            caps: okCaps
        )
        XCTAssertEqual(list.first?.id, "print-error")
        XCTAssertEqual(list.first?.level, .error)
        XCTAssertEqual(list.first?.detail.contains("84033543"), true)
        XCTAssertEqual(list.first?.actions.map(\.id), [.resume, .stop])
    }

    func testAFailedStateWithNoCodeStillRaisesTheError() {
        let list = Alerts.present(printerStatus { $0.state = "ERROR" }, caps: okCaps)
        XCTAssertEqual(list.first?.id, "print-error")
        XCTAssertEqual(list.first?.detail, "The printer stopped with an error. Check the machine before continuing.")
    }

    // MARK: - Swift-specific edges

    func testAZeroPrintErrorMeansNoError() {
        // A JS `if (status.print_error)` treated 0 as absent, and so must this.
        XCTAssertEqual(Alerts.present(printerStatus { $0.printError = 0 }, caps: okCaps), [])
    }

    func testSeverityArrivingAsAJsonStringStillMapsToItsRung() throws {
        // The WebSocket feed stringifies numerics, so `LooseNumber` can hold a decoded "3".
        let stringy = try JSONDecoder().decode(LooseNumber.self, from: Data("\"3\"".utf8))
        let a = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice(severity: stringy)] }, caps: okCaps)))
        XCTAssertEqual(a.title, "Common notice")
        XCTAssertEqual(a.level, .warning)
    }

    func testASeverityNoIntCanHoldDoesNotTrapAndStaysNeutral() throws {
        for wild: LooseNumber in [LooseNumber(1e30), LooseNumber(-1e30), LooseNumber(3.5), LooseNumber(.nan), LooseNumber(.infinity)] {
            let a = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice(severity: wild)] }, caps: okCaps)))
            XCTAssertEqual(a.title, "Printer notice", "severity \(String(describing: wild.double))")
            XCTAssertEqual(a.level, .warning)
        }
    }

    func testAPrintErrorNoIntCanHoldDoesNotTrap() throws {
        let list = Alerts.present(printerStatus { $0.printError = LooseNumber(1e30) }, caps: okCaps)
        XCTAssertEqual(list.first?.id, "print-error")
        XCTAssertTrue(try XCTUnwrap(list.first?.detail).contains("Check the machine"))
    }

    func testANonFinitePrintErrorIsNotAnError() {
        XCTAssertEqual(Alerts.present(printerStatus { $0.printError = LooseNumber(.nan) }, caps: okCaps), [])
    }

    func testANoticeWithNoCodeAtAllIsStillListed() throws {
        let a = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [HmsError()] }, caps: okCaps)))
        XCTAssertEqual(a.id, "hms-0")
        XCTAssertNil(a.code)
        XCTAssertEqual(a.detail, "The printer raised a health notice with no code attached.")
        // Nothing to look up without a code — but the batch dismiss is still on offer.
        XCTAssertEqual(a.actions.map(\.id), [.clearHms])
    }

    func testACodeThatIsNotSixteenHexDigitsIsPassedThroughUnchanged() throws {
        let a = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice(fullCode: "0x10007")] }, caps: okCaps)))
        XCTAssertEqual(a.code, "0x10007")
        XCTAssertTrue(try XCTUnwrap(lookupURLs(a).first).hasSuffix("/hmscode/0x10007"))
    }

    func testFullCodeWinsOverCodeAndAnEmptyOneFallsThrough() throws {
        let both = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice()] }, caps: okCaps)))
        XCTAssertEqual(both.code, "0500-0500-0001-0007")
        // No full_code: the short `code` is all there is.
        let short = try XCTUnwrap(firstHms(Alerts.present(printerStatus { $0.hmsErrors = [notice(fullCode: nil)] }, caps: okCaps)))
        XCTAssertEqual(short.code, "0x10007")
    }

    func testEveryAlertKindCanAppearAtOnceAndTheOrderIsFixed() {
        let list = Alerts.present(
            printerStatus {
                $0.state = "PAUSE"
                $0.printError = 1
                $0.awaitingPlateClear = true
                $0.hmsErrors = [notice(severity: 3)]
            },
            caps: okCaps
        )
        XCTAssertEqual(list.map(\.id), ["print-error", "paused", "plate", "hms-0500-0500-0001-0007"])
    }

    // MARK: - alertSummary — the single dashboard row

    func testSummaryIsNilWhenAllIsWell() {
        XCTAssertNil(Alerts.summary([]))
    }

    func testSummaryReportsTheWorstLevelPresent() {
        let list = Alerts.present(
            printerStatus {
                $0.state = "PAUSE"
                $0.hmsErrors = [HmsError(severity: 4, fullCode: "0500050000010007")]
            },
            caps: okCaps
        )
        // Paused outranks an info notice.
        XCTAssertEqual(Alerts.summary(list)?.level, .warning)
        let fatal = Alerts.present(printerStatus { $0.printError = 1 }, caps: okCaps)
        XCTAssertEqual(Alerts.summary(fatal)?.level, .error)
    }

    func testSummaryCountsHowManyAreActionableIgnoringLookupOnlyRows() {
        let list = Alerts.present(
            printerStatus { $0.hmsErrors = [HmsError(severity: 4, fullCode: "0500050000010007")] },
            caps: okCaps
        )
        // One notice: it has lookup + the batch dismiss -> actionable.
        XCTAssertEqual(Alerts.summary(list)?.label, "1 alert · 1 actionable")
        XCTAssertEqual(Alerts.summary(list)?.count, 1)

        let offline = Alerts.present(
            printerStatus {
                $0.connected = false
                $0.hmsErrors = [HmsError(severity: 4, fullCode: "0500050000010007")]
            },
            caps: AlertCaps(connected: false, canControl: true)
        )
        // Nothing actionable while offline.
        XCTAssertEqual(Alerts.summary(offline)?.label, "1 alert")
    }

    func testSummaryPluralisesTheNoun() {
        let list = Alerts.present(
            printerStatus {
                $0.state = "PAUSE"
                $0.awaitingPlateClear = true
            },
            caps: AlertCaps(connected: false, canControl: false)
        )
        XCTAssertEqual(Alerts.summary(list)?.label, "2 alerts")
    }

    func testSummaryCountsAreNeverLocaleGrouped() {
        // Plain interpolation, never a NumberFormatter: "1234", not "1,234" or "1 234".
        let many = (0..<1234).map { AlertVM(id: "\($0)", level: .info, title: "", detail: "", actions: []) }
        XCTAssertEqual(Alerts.summary(many)?.label, "1234 alerts")
    }

    func testTheLevelLadderRunsInfoWarningError() {
        XCTAssertTrue(AlertLevel.info < AlertLevel.warning)
        XCTAssertTrue(AlertLevel.warning < AlertLevel.error)
        XCTAssertEqual([AlertLevel.info, .error, .warning].max(), .error)
    }

    // MARK: - wikiFamily

    func testWikiFamilyMapsEachBambuModelLine() {
        XCTAssertEqual(Alerts.wikiFamily("H2C"), "h2")
        XCTAssertEqual(Alerts.wikiFamily("H2D"), "h2")
        XCTAssertEqual(Alerts.wikiFamily("X1C"), "x1")
        XCTAssertEqual(Alerts.wikiFamily("P1S"), "p1")
        XCTAssertEqual(Alerts.wikiFamily("A1 mini"), "a1")
    }

    func testWikiFamilyFallsBackToTheLargestLegacySet() {
        XCTAssertEqual(Alerts.wikiFamily("SomeNewPrinter"), "x1")
        XCTAssertEqual(Alerts.wikiFamily(nil), "x1")
        XCTAssertEqual(Alerts.wikiFamily(""), "x1")
    }

    func testWikiFamilyIgnoresSurroundingWhitespaceAndCase() {
        XCTAssertEqual(Alerts.wikiFamily("  a1 mini \n"), "a1")
        XCTAssertEqual(Alerts.wikiFamily("h2c"), "h2")
    }

    // MARK: - unknownCodes

    func testUnknownCodesPicksOnlyTheRowsTheCatalogueCannotDescribe() {
        let catalog = HmsCatalog(hms: ["0500050000010007": "Known."])
        let list = Alerts.present(
            printerStatus { $0.hmsErrors = [notice(), notice(fullCode: "0C00010000020017")] },
            caps: okCaps
        )
        let targets = Alerts.unknownCodes(in: list, catalog: catalog)
        XCTAssertEqual(targets.map(\.code), ["0C00-0100-0002-0017"])
        XCTAssertEqual(targets.first?.urls.count, 5)
    }

    func testUnknownCodesSkipsAlertsThatCarryNoCode() {
        let list = Alerts.present(printerStatus { $0.state = "PAUSE" }, caps: okCaps)
        XCTAssertEqual(Alerts.unknownCodes(in: list, catalog: .empty), [])
    }
}

// MARK: - Local HMS descriptions (Bambu's own feed)

final class HmsCatalogTests: XCTestCase {

    /// Verbatim shape of Bambu's public code feed (4,882 hms + 654 error entries live).
    private let feed = Data(#"""
    {"data":{
      "device_hms":{"ver":1,"en":[{"ecode":"0501040000030002","intro":"Threaded rods need lubrication now."}]},
      "device_error":{"ver":1,"en":[{"ecode":"18048012","intro":"Failed to get AMS mapping table; please select \"Resume\" to retry."}]}
    }}
    """#.utf8)

    private func loadedCatalog() -> HmsCatalog {
        let parsed = HmsCatalog.parseFeed(feed)
        return HmsCatalog(hms: parsed.hms, err: parsed.err, fetchedAt: Date())
    }

    func testParsesBothSectionsIntoLookupMaps() {
        let cat = loadedCatalog()
        XCTAssertEqual(cat.hms.count, 1)
        XCTAssertEqual(cat.err.count, 1)
    }

    func testLooksUpByTheDashedDisplayCodeAsWellAsRawHex() {
        let cat = loadedCatalog()
        XCTAssertEqual(cat.describeHms("0501-0400-0003-0002"), "Threaded rods need lubrication now.")
        XCTAssertEqual(cat.describeHms("0501040000030002"), "Threaded rods need lubrication now.")
        XCTAssertEqual(cat.describeHms("0501_0400_0003_0002"), "Threaded rods need lubrication now.")
        XCTAssertEqual(cat.describeHms(" 0501 0400 0003 0002 "), "Threaded rods need lubrication now.")
        // The feed uppercases its keys, so a lower-case code from the printer must still hit.
        XCTAssertEqual(cat.describeHms("0501-0400-0003-0002".lowercased()), "Threaded rods need lubrication now.")
    }

    func testReturnsNilForACodeTheFeedDoesNotCover() {
        let cat = loadedCatalog()
        XCTAssertNil(cat.describeHms("0C00-0100-0002-0017")) // the H2C fatal is one
        XCTAssertNil(cat.describeHms(nil))
        XCTAssertNil(cat.describeHms(""))
    }

    func testFallsBackToALearnedDescription() {
        var cat = loadedCatalog()
        cat.learned["0C00010000020017"] = "Nozzle camera lens is dirty."
        XCTAssertEqual(cat.describeHms("0C00-0100-0002-0017"), "Nozzle camera lens is dirty.")
    }

    func testResolvesPrintErrorNumbersToo() {
        let cat = loadedCatalog()
        XCTAssertEqual(cat.describePrintError(18_048_012)?.contains("AMS mapping table"), true)
        XCTAssertNil(cat.describePrintError(999))
        XCTAssertNil(cat.describePrintError(nil))
        XCTAssertNil(cat.describePrintError(key: ""))
        XCTAssertEqual(cat.describePrintError(key: "18048012")?.contains("AMS mapping table"), true)
    }

    func testPresentShowsBambusWordingWhenAvailableAndGenericCopyWhenNot() {
        let describe = AlertDescribe(catalog: loadedCatalog())
        let withText = Alerts.present(
            printerStatus { $0.hmsErrors = [HmsError(severity: 4, fullCode: "0501040000030002")] },
            caps: okCaps,
            describe: describe
        )
        XCTAssertEqual(withText.first?.detail, "Threaded rods need lubrication now.")

        let without = Alerts.present(
            printerStatus { $0.hmsErrors = [HmsError(severity: 1, fullCode: "0C00010000020017")] },
            caps: okCaps,
            describe: describe
        )
        XCTAssertEqual(without.first?.detail.lowercased().contains("serious condition"), true)
    }

    func testPresentShowsBambusWordingForAPrintErrorToo() {
        let describe = AlertDescribe(catalog: loadedCatalog())
        let list = Alerts.present(printerStatus { $0.printError = 18_048_012 }, caps: okCaps, describe: describe)
        XCTAssertEqual(list.first?.detail.contains("AMS mapping table"), true)
        // An unknown code keeps the generic sentence, with the number in it.
        let unknown = Alerts.present(printerStatus { $0.printError = 999 }, caps: okCaps, describe: describe)
        XCTAssertEqual(unknown.first?.detail, "The printer reported error 999. Check the machine before continuing.")
    }

    func testACatalogCachedByAnOlderBuildHasNoLearnedMapAndStillDecodes() throws {
        let legacy = Data(#"{"hms":{"0501040000030002":"x"},"err":{}}"#.utf8)
        let cat = try JSONDecoder().decode(HmsCatalog.self, from: legacy)
        XCTAssertEqual(cat.describeHms("0501-0400-0003-0002"), "x")
        XCTAssertNil(cat.describeHms("0C00-0100-0002-0017"))
        XCTAssertNil(cat.describePrintError(1))
        XCTAssertTrue(cat.learned.isEmpty)
        // No timestamp either — which must read as "ancient", so the next load refetches.
        XCTAssertGreaterThan(Date().timeIntervalSince(cat.fetchedAt), HmsCatalogStore.maxAge)
    }

    func testCatalogSurvivesACodableRoundTrip() throws {
        var cat = loadedCatalog()
        cat.learned["0C00010000020017"] = "Nozzle camera lens is dirty."
        let data = try JSONEncoder().encode(cat)
        XCTAssertEqual(try JSONDecoder().decode(HmsCatalog.self, from: data), cat)
    }

    func testAMalformedFeedYieldsEmptyMapsRatherThanThrowing() {
        for raw in ["{}", "null", "[]", "", "not json", #"{"data":{"device_hms":{"en":"nope"}}}"#] {
            let parsed = HmsCatalog.parseFeed(Data(raw.utf8))
            XCTAssertTrue(parsed.hms.isEmpty, raw)
            XCTAssertTrue(parsed.err.isEmpty, raw)
        }
    }

    func testFeedEntriesMissingACodeOrIntroAreSkipped() {
        let raw = #"""
        {"data":{"device_hms":{"en":[
          {"ecode":"0501040000030002"},
          {"intro":"orphan"},
          {"ecode":"  ","intro":"blank"},
          {"ecode":"0300010000010001","intro":"  kept  "}
        ]}}}
        """#
        let parsed = HmsCatalog.parseFeed(Data(raw.utf8))
        XCTAssertEqual(parsed.hms, ["0300010000010001": "kept"])
    }

    func testANumericEcodeIsNotSilentlyDropped() {
        // Bambu writes codes as strings; a number there must still land in the map.
        let raw = #"{"data":{"device_error":{"en":[{"ecode":18048012,"intro":"AMS mapping table."}]}}}"#
        XCTAssertEqual(HmsCatalog.parseFeed(Data(raw.utf8)).err, ["18048012": "AMS mapping table."])
    }

    func testHmsKeysAreUppercasedOnTheWayIn() {
        // Hex codes arrive in either case; the decimal print-error keys have no case to normalise.
        let raw = #"""
        {"data":{
          "device_hms":{"en":[{"ecode":"0c00010000020017","intro":"lower"}]},
          "device_error":{"en":[{"ecode":"18048012","intro":"decimal"}]}
        }}
        """#
        let parsed = HmsCatalog.parseFeed(Data(raw.utf8))
        XCTAssertEqual(parsed.hms, ["0C00010000020017": "lower"])
        XCTAssertEqual(parsed.err, ["18048012": "decimal"])
    }

    // MARK: - parseWikiTitle — codes the feed does not carry

    /// Verbatim from the wiki page for 0C00_0100_0002_0017.
    private let page = """
    <html><head><title>HMS_0C00-0100-0002-0017: Nozzle camera lens is dirty, which may affect the AI monitoring functionality. Please clean the surface of the nozzle camera lens as soon as possible.  | Bambu Lab Wiki</title>
      <meta property="og:title" content="HMS_0C00-0100-0002-0017: Nozzle camera lens is dirty, which may affect the AI monitoring functionality. Please clean the surface of the nozzle camera lens as soon as possible." />
      <meta property="og:description" content="0C00-0100-0002-0017" /></head><body>x</body></html>
    """

    func testExtractsTheSentenceAndStripsTheHmsCodePrefix() {
        XCTAssertEqual(
            HmsCatalog.parseWikiTitle(page),
            "Nozzle camera lens is dirty, which may affect the AI monitoring functionality. Please clean the surface of the nozzle camera lens as soon as possible."
        )
    }

    func testFallsBackToTheTitleTagWhenOgTitleIsAbsentDroppingTheSiteSuffix() {
        let noOg = "<html><head><title>HMS_0300-0100-0001-0001: Something is wrong. | Bambu Lab Wiki</title></head></html>"
        XCTAssertEqual(HmsCatalog.parseWikiTitle(noOg), "Something is wrong.")
    }

    func testReturnsNilForAPageWithNoUsableTitle() {
        XCTAssertNil(HmsCatalog.parseWikiTitle("<html><body>404</body></html>"))
        XCTAssertNil(HmsCatalog.parseWikiTitle("<html><head><title>  </title></head></html>"))
        XCTAssertNil(HmsCatalog.parseWikiTitle(""))
        // Three characters or fewer is a placeholder, not a description.
        XCTAssertNil(HmsCatalog.parseWikiTitle("<html><head><title>404</title></head></html>"))
    }

    func testTitleMatchingIsCaseInsensitiveInBothTagAndAttribute() {
        let shouty = #"<HTML><HEAD><META PROPERTY="OG:TITLE" CONTENT="HMS_0300-0100-0001-0001: Shouty page." /></HEAD></HTML>"#
        XCTAssertEqual(HmsCatalog.parseWikiTitle(shouty), "Shouty page.")
    }

    func testATitleWithoutTheHmsPrefixIsKeptWhole() {
        let plain = "<html><head><title>Troubleshooting guide | Bambu Lab Wiki</title></head></html>"
        XCTAssertEqual(HmsCatalog.parseWikiTitle(plain), "Troubleshooting guide")
    }

    // MARK: - Store

    func testLoadServesAFreshDiskCacheWithoutTouchingTheNetwork() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Written by an OLDER build: no `learned` map at all.
        let json = #"""
        {"hms":{"0501040000030002":"Threaded rods need lubrication now."},"err":{},"fetchedAt":\#(Date().timeIntervalSinceReferenceDate)}
        """#
        try Data(json.utf8).write(to: dir.appending(path: "hms-catalog.json"))

        // The transport fails everything, so anything that arrives came off disk.
        let store = HmsCatalogStore(session: stubSession(OfflineProtocol.self), cacheDirectory: dir)
        let cat = await store.load()
        XCTAssertEqual(cat.describeHms("0501-0400-0003-0002"), "Threaded rods need lubrication now.")
        XCTAssertTrue(cat.learned.isEmpty)
        // Held in memory now, so a second call answers from the memo.
        let again = await store.load()
        XCTAssertEqual(again, cat)
    }

    func testAStaleDiskCacheIsDiscardedRatherThanServed() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ancient = Date().addingTimeInterval(-(HmsCatalogStore.maxAge + 60)).timeIntervalSinceReferenceDate
        let json = #"""
        {"hms":{"0501040000030002":"stale"},"err":{},"learned":{},"fetchedAt":\#(ancient)}
        """#
        try Data(json.utf8).write(to: dir.appending(path: "hms-catalog.json"))

        // Refresh fails, and the fallback is an empty catalogue — an alert with no prose beats one
        // captioned with text a fortnight out of date.
        let store = HmsCatalogStore(session: stubSession(OfflineProtocol.self), cacheDirectory: dir)
        let cat = await store.load()
        XCTAssertNil(cat.describeHms("0501-0400-0003-0002"))
    }

    func testAFetchedFeedIsParsedMemoisedAndWrittenToDisk() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HmsCatalogStore(session: stubSession(CannedBambuProtocol.self), cacheDirectory: dir)
        let fetched = await store.load()
        XCTAssertEqual(fetched.describeHms("0501-0400-0003-0002"), "Threaded rods need lubrication now.")

        // A second store over the same directory reads what the first wrote, with no transport at all.
        let reopened = HmsCatalogStore(session: stubSession(OfflineProtocol.self), cacheDirectory: dir)
        let fromDisk = await reopened.load()
        XCTAssertEqual(fromDisk.describeHms("0501040000030002"), "Threaded rods need lubrication now.")
    }

    func testLearnRecordsAWikiDescriptionUnderTheStrippedKeyAndPersistsIt() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HmsCatalogStore(session: stubSession(CannedBambuProtocol.self), cacheDirectory: dir)
        let target = HmsLookupTarget(code: "0C00-0100-0002-0017", urls: Alerts.hmsURLs("0C00-0100-0002-0017", model: "H2C"))
        let cat = await store.learn([target])
        XCTAssertEqual(cat.describeHms("0C00-0100-0002-0017"), "Nozzle camera lens is dirty.")
        XCTAssertEqual(cat.learned["0C00010000020017"], "Nozzle camera lens is dirty.")
        // The feed's own entries survive alongside it.
        XCTAssertEqual(cat.describeHms("0501040000030002"), "Threaded rods need lubrication now.")

        // A given code costs one request ever: the answer is on disk for the next launch.
        let reopened = HmsCatalogStore(session: stubSession(OfflineProtocol.self), cacheDirectory: dir)
        let fromDisk = await reopened.load()
        XCTAssertEqual(fromDisk.describeHms("0C00-0100-0002-0017"), "Nozzle camera lens is dirty.")
    }

    func testLearnLeavesACodeTheFeedAlreadyCoversAlone() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = HmsCatalogStore(session: stubSession(CannedBambuProtocol.self), cacheDirectory: dir)
        let known = HmsLookupTarget(code: "0501-0400-0003-0002", urls: Alerts.hmsURLs("0501-0400-0003-0002", model: "A1"))
        let cat = await store.learn([known])
        // The wiki page would have overwritten it with the H2C sentence had it been fetched at all.
        XCTAssertEqual(cat.describeHms("0501-0400-0003-0002"), "Threaded rods need lubrication now.")
        XCTAssertTrue(cat.learned.isEmpty)
    }
}

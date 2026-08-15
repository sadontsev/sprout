// The Mac Jobs section's pure logic: the row projection, the outcome vocabulary, the lifetime
// figures, and the three "what is this block actually showing" decisions.
//
// **These cases only run on the macOS test destination.** The types are inside `#if os(macOS)`
// because they are Mac layout support, so the iOS command in CLAUDE.md contributes zero cases from
// this file — a green iOS run is not evidence that any of this passed. Run
// `xcodebuild … -destination 'platform=macOS' test` as well (18-mac-port-architecture.md, Build).
#if os(macOS)
import XCTest
@testable import Sprout

// MARK: - Fixtures

private func makeEntry(
    id: Int = 1,
    archiveId: Int? = 77,
    printName: String? = "bracket.3mf",
    printerName: String? = "H2C",
    status: String = "completed",
    startedAt: String? = "2026-06-28T15:07:35.681213",
    durationSeconds: LooseNumber? = nil,
    filamentType: String? = nil,
    filamentColor: String? = nil,
    filamentUsedGrams: LooseNumber? = nil,
    cost: LooseNumber? = nil,
    energyKwh: LooseNumber? = nil,
    energyCost: LooseNumber? = nil
) -> PrintLogEntry {
    PrintLogEntry(
        id: id,
        archiveId: archiveId,
        printName: printName,
        printerName: printerName,
        printerId: 1,
        status: status,
        startedAt: startedAt,
        completedAt: nil,
        durationSeconds: durationSeconds,
        filamentType: filamentType,
        filamentColor: filamentColor,
        filamentUsedGrams: filamentUsedGrams,
        cost: cost,
        energyKwh: energyKwh,
        energyCost: energyCost,
        failureReason: nil,
        thumbnailPath: nil,
        createdAt: nil
    )
}

private func makeQueueItem(
    id: Int = 1,
    status: String = "pending",
    printerId: Int? = nil,
    printerName: String? = nil,
    libraryFileName: String? = "part.3mf",
    printTimeSeconds: LooseNumber? = nil
) -> QueueItem {
    QueueItem(
        id: id,
        status: status,
        position: nil,
        printerId: printerId,
        printerName: printerName,
        libraryFileName: libraryFileName,
        archiveName: nil,
        libraryFileThumbnail: nil,
        archiveThumbnail: nil,
        printTimeSeconds: printTimeSeconds
    )
}

private func makeStats(
    totalPrints: Int? = 100,
    successfulPrints: Int? = 94,
    totalPrintTimeHours: LooseNumber? = 1248.04,
    totalFilamentGrams: LooseNumber? = 41200,
    totalCost: LooseNumber? = nil
) -> ArchiveStats {
    ArchiveStats(
        totalPrints: totalPrints,
        successfulPrints: successfulPrints,
        failedPrints: nil,
        cancelledPrints: nil,
        totalPrintTimeHours: totalPrintTimeHours,
        totalFilamentGrams: totalFilamentGrams,
        totalCost: totalCost,
        printsByFilamentType: nil,
        printsByPrinter: nil,
        totalEnergyKwh: nil,
        totalEnergyCost: nil,
        energyDataWarmingUp: nil
    )
}

private func row(_ e: PrintLogEntry, symbol: String = "£") -> MacJobRow {
    MacJobRow(e, symbol: symbol, client: nil, cameraToken: nil)
}

final class MacJobsRowTests: XCTestCase {

    // MARK: Cost

    func testFallsBackToEnergyCostWhenTheArchiveHasNoFilamentCost() {
        XCTAssertEqual(row(makeEntry(cost: 2.5, energyCost: 9.9)).costText, "£2.50")
        XCTAssertEqual(row(makeEntry(cost: nil, energyCost: 0.31)).costText, "£0.31")
    }

    /// Zero is "the server has not costed this yet", not "this print was free".
    func testShowsAnEmDashRatherThanZeroWhenNothingIsCosted() {
        let r = row(makeEntry())
        XCTAssertEqual(r.cost, 0)
        XCTAssertEqual(r.costText, "—")
    }

    func testRendersTheSessionsCurrencyRatherThanADefaultDollar() {
        XCTAssertEqual(row(makeEntry(cost: 4), symbol: "SEK ").costText, "SEK 4.00")
    }

    // MARK: Duration

    func testTreatsZeroSecondsAsUnknownRatherThanInstant() {
        XCTAssertEqual(row(makeEntry(durationSeconds: 0)).durationText, "—")
        XCTAssertEqual(row(makeEntry(durationSeconds: nil)).durationText, "—")
        XCTAssertEqual(row(makeEntry(durationSeconds: 5400)).durationText, "1h 30m")
    }

    // MARK: Sorting sentinels

    func testUndatedRunsSortToOneEndInsteadOfInterleaving() {
        let undated = row(makeEntry(startedAt: nil))
        XCTAssertNil(undated.startedDate)
        XCTAssertEqual(undated.started, .distantPast)
        XCTAssertEqual(undated.startedText, "")
        // The inspector's absolute timestamp is empty rather than a formatted `.distantPast`.
        XCTAssertEqual(undated.startedAbsolute, "")

        let dated = row(makeEntry())
        XCTAssertNotNil(dated.startedDate)
        XCTAssertGreaterThan(dated.started, .distantPast)
        XCTAssertFalse(dated.startedAbsolute.isEmpty)
    }

    func testSortsNewestFirstOnTheParsedDateNotTheFriendlyText() {
        let older = row(makeEntry(id: 1, startedAt: "2026-06-01T09:00:00"))
        let newer = row(makeEntry(id: 2, startedAt: "2026-06-28T15:07:35.681213"))
        let undated = row(makeEntry(id: 3, startedAt: nil))
        let sorted = [older, undated, newer]
            .sorted(using: [KeyPathComparator(\MacJobRow.started, order: .reverse)])
        XCTAssertEqual(sorted.map(\.id), [2, 1, 3])
    }

    // MARK: Filament

    func testTakesTheFirstColourOfAMultiMaterialString() {
        XCTAssertEqual(row(makeEntry(filamentColor: "#565656, #000000")).swatch, "#565656")
        XCTAssertNil(row(makeEntry(filamentColor: nil)).swatch)
        // Bambu's "unset" alpha is not a colour — `FilamentColor.norm` rejects it.
        XCTAssertNil(row(makeEntry(filamentColor: "00000000")).swatch)
    }

    func testShowsTheTypeInTheColumnAndAssemblesGramsPlusTypeForTheInspector() {
        let both = row(makeEntry(filamentType: " PLA Basic ", filamentUsedGrams: 111.6))
        XCTAssertEqual(both.filament, "PLA Basic")
        XCTAssertEqual(both.filamentDetail, "112 g PLA Basic")

        // Either half is worth showing on its own.
        XCTAssertEqual(row(makeEntry(filamentType: "PETG-CF")).filamentDetail, "PETG-CF")
        XCTAssertEqual(row(makeEntry(filamentUsedGrams: 40)).filamentDetail, "40 g")
        XCTAssertEqual(row(makeEntry()).filamentDetail, "—")
        XCTAssertEqual(row(makeEntry()).filament, "—")
        // Zero grams is "not recorded", not a weightless print.
        XCTAssertEqual(row(makeEntry(filamentType: "PLA", filamentUsedGrams: 0)).filamentDetail, "PLA")
    }

    // MARK: Energy

    func testNeverReportsZeroKwhWhichWouldReadAsUsingNoPower() {
        XCTAssertEqual(row(makeEntry(energyKwh: 0)).energyText, "—")
        XCTAssertEqual(row(makeEntry(energyKwh: nil)).energyText, "—")
        XCTAssertEqual(row(makeEntry(energyKwh: 1.234)).energyText, "1.23 kWh")
    }

    // MARK: Reprint gate

    func testCarriesTheArchiveIdVerbatimBecauseItIsTheReprintGate() {
        XCTAssertEqual(row(makeEntry(archiveId: 42)).archiveId, 42)
        // A print started from the printer's own screen has no archive row behind it.
        XCTAssertNil(row(makeEntry(archiveId: nil)).archiveId)
    }

    func testNamesAnUnnamedRunRatherThanRenderingAnEmptyCell() {
        XCTAssertEqual(row(makeEntry(archiveId: nil, printName: nil)).name, "Print 1")
    }
}

// MARK: - Outcome

final class MacJobOutcomeTests: XCTestCase {

    func testMapsTheThreeKnownStatusesToTheSameWordsTheIosArchiveUses() {
        XCTAssertEqual(MacJobOutcome(status: "completed").label, "Done")
        XCTAssertEqual(MacJobOutcome(status: "failed").label, "Failed")
        XCTAssertEqual(MacJobOutcome(status: "cancelled").label, "Canceled")
    }

    /// An unrecognised status keeps the server's own word rather than being flattened into "Failed",
    /// which would be the app inventing an outcome.
    func testKeepsAnUnknownStatusCapitalisedRatherThanFlatteningIt() {
        XCTAssertEqual(MacJobOutcome(status: "paused").label, "Paused")
        XCTAssertEqual(MacJobOutcome(status: "heat_bed_error").label, "Heat_bed_error")
        XCTAssertEqual(MacJobOutcome(status: "").label, "Unknown")
        XCTAssertEqual(MacJobOutcome(status: "x").label, "X")
    }

    func testColoursSuccessAndFailureApartAndTreatsAnythingUnknownAsNeutral() {
        let p = Palette.dark
        XCTAssertEqual(MacJobOutcome(status: "completed").color(p), p.running)
        XCTAssertEqual(MacJobOutcome(status: "failed").color(p), p.error)
        XCTAssertEqual(MacJobOutcome(status: "cancelled").color(p), p.idle)
        XCTAssertEqual(MacJobOutcome(status: "who knows").color(p), p.idle)
        XCTAssertEqual(MacJobOutcome(status: "completed").dim(p), p.runningDim)
        XCTAssertEqual(MacJobOutcome(status: "failed").dim(p), p.errorDim)
    }
}

// MARK: - Lifetime figures

final class MacJobStatsTests: XCTestCase {

    func testRoundsTheSuccessPercentageAndSaysNothingWithoutPrints() {
        XCTAssertEqual(MacJobStats.successText(makeStats(totalPrints: 100, successfulPrints: 94)), "94 % success")
        // 2/3 rounds to 67, not 66.
        XCTAssertEqual(MacJobStats.successText(makeStats(totalPrints: 3, successfulPrints: 2)), "67 % success")
        XCTAssertEqual(MacJobStats.successText(makeStats(totalPrints: 0, successfulPrints: 0)), "")
        XCTAssertEqual(MacJobStats.successText(makeStats(totalPrints: nil)), "")
        XCTAssertEqual(MacJobStats.successText(makeStats(totalPrints: 4, successfulPrints: nil)), "0 % success")
    }

    func testSwitchesToKilogramsOnlyOnceThereIsAKilogramToShow() {
        XCTAssertEqual(
            MacJobStats.totalsText(makeStats(totalPrintTimeHours: 1248.04, totalFilamentGrams: 41200)),
            "1248.0 h · 41.20 kg filament"
        )
        // 999 g stays grams; 1000 g is the threshold and flips.
        XCTAssertEqual(
            MacJobStats.totalsText(makeStats(totalPrintTimeHours: 0, totalFilamentGrams: 999.4)),
            "0.0 h · 999 g filament"
        )
        XCTAssertEqual(
            MacJobStats.totalsText(makeStats(totalPrintTimeHours: 1, totalFilamentGrams: 1000)),
            "1.0 h · 1.00 kg filament"
        )
        XCTAssertEqual(
            MacJobStats.totalsText(makeStats(totalPrintTimeHours: nil, totalFilamentGrams: nil)),
            "0.0 h · 0 g filament"
        )
    }
}

// MARK: - Queue subtitle

final class MacJobQueueTests: XCTestCase {

    func testFallsBackToTheRawStatusWhenAJobHasNoTimeEstimate() {
        XCTAssertEqual(MacJobQueue.subtitle(makeQueueItem(status: "pending")), "pending")
        XCTAssertEqual(MacJobQueue.subtitle(makeQueueItem(printTimeSeconds: 0)), "pending")
        XCTAssertEqual(MacJobQueue.subtitle(makeQueueItem(printTimeSeconds: 3600)), "1h 00m")
    }
}

// MARK: - What each block is showing

final class MacJobsQueueBodyTests: XCTestCase {

    private func body(_ queue: [QueueItem]?, failed: Bool = false, printerId: Int = 1) -> MacJobsQueueBody {
        MacJobsQueueBody.of(queue: queue, failed: failed, printerId: printerId)
    }

    func testSpinsOnlyBeforeTheFirstAnswer() {
        XCTAssertEqual(body(nil), .loading)
    }

    /// The regression this enum exists for: `JobsStore.loadQueue` falls back to `queue ?? []`, so a
    /// cold failure leaves an EMPTY array behind. "Empty" must not be read as "nothing is queued".
    func testDoesNotClaimTheQueueIsEmptyWhenTheFetchNeverAnswered() {
        XCTAssertEqual(body([], failed: true), .unknown)
        XCTAssertEqual(body(nil, failed: true), .unknown)
    }

    func testKeepsShowingStaleRowsUnderTheRetryBanner() {
        XCTAssertEqual(body([makeQueueItem()], failed: true), .rows)
    }

    /// The second regression: `upNext` is THIS PRINTER'S lane. A queue full of another machine's
    /// jobs is not an empty queue, and saying so contradicted the line printed directly below it.
    func testDistinguishesAnEmptyQueueFromOneWhoseJobsBelongToAnotherPrinter() {
        XCTAssertEqual(body([]), .emptyEverywhere)
        XCTAssertEqual(body([makeQueueItem(printerId: 2)]), .elsewhereOnly)
        XCTAssertEqual(body([makeQueueItem(printerId: 2), makeQueueItem(id: 2, printerId: 1)]), .rows)
        // An untargeted job can land here, so it belongs to this lane.
        XCTAssertEqual(body([makeQueueItem(printerId: nil)]), .rows)
    }

    /// Only PENDING jobs are queued: the one that is printing is the strip above, not a queue row.
    func testIgnoresJobsThatAreNoLongerWaiting() {
        XCTAssertEqual(body([makeQueueItem(status: "printing"), makeQueueItem(id: 2, status: "completed")]), .emptyEverywhere)
        XCTAssertEqual(body([makeQueueItem(status: "queued")]), .rows)
    }
}

final class MacJobsHistoryBodyTests: XCTestCase {

    func testTellsNeverLoadedApartFromEmptyApartFromFailed() {
        XCTAssertEqual(MacJobsHistoryBody.of(entries: nil, failed: false), .loading)
        XCTAssertEqual(MacJobsHistoryBody.of(entries: [], failed: false), .empty)
        // The same `entries ?? []` fallback as the queue: a cold failure must not read as "no
        // prints yet", which asserts an archive the app never managed to read.
        XCTAssertEqual(MacJobsHistoryBody.of(entries: [], failed: true), .unknown)
        XCTAssertEqual(MacJobsHistoryBody.of(entries: [makeEntry()], failed: true), .rows)
        XCTAssertEqual(MacJobsHistoryBody.of(entries: [makeEntry()], failed: false), .rows)
    }
}

final class MacJobsLifetimeBodyTests: XCTestCase {

    private func lifetime(
        stats: ArchiveStats?,
        statsAsked: Bool = true,
        statsFailed: Bool = false,
        entries: [PrintLogEntry]?,
        historyFailed: Bool = false
    ) -> MacJobsLifetimeBody {
        MacJobsLifetimeBody.of(
            stats: stats,
            statsAsked: statsAsked,
            statsFailed: statsFailed,
            entries: entries,
            historyFailed: historyFailed
        )
    }

    func testShowsTheFiguresWheneverTheSummaryAnsweredWithPrintsInIt() {
        XCTAssertEqual(lifetime(stats: makeStats(), entries: [makeEntry()]), .figures(makeStats()))
    }

    /// **The regression this signature exists for.** `JobsStore.loadHistory` assigns `entries` and
    /// only THEN awaits the summary, so on every cold load the observed state is exactly this —
    /// runs on screen, `stats` still nil, nothing failed. Keyed on `stats == nil` the card fell
    /// through to "Lifetime totals unavailable · it didn't answer" about a request that had not
    /// answered YET. Only `statsAsked` tells in-flight from refused; the nil is identical in both.
    func testDoesNotCallTheSummaryUnavailableWhileItIsStillInFlight() {
        XCTAssertEqual(lifetime(stats: nil, statsAsked: false, entries: [makeEntry()]), .loading)
        XCTAssertEqual(lifetime(stats: nil, statsAsked: false, entries: []), .loading)
        // Mid-load after the LIST itself failed: the summary is still in flight all the same.
        XCTAssertEqual(
            lifetime(stats: nil, statsAsked: false, entries: [], historyFailed: true),
            .loading
        )
    }

    /// Once it HAS been asked and refused, the card says so — and says which of the two things went
    /// wrong, because the help text names a request that did not answer.
    func testSaysUnavailableOnlyOnceTheSummaryHasActuallyBeenRefused() {
        XCTAssertEqual(
            lifetime(stats: nil, statsFailed: true, entries: [makeEntry()]),
            .unavailable(.requestFailed)
        )
        XCTAssertEqual(lifetime(stats: nil, statsFailed: true, entries: nil), .unavailable(.requestFailed))
    }

    /// A failed refresh no longer clears the previous summary, so a card reading "213 · 94 %
    /// success" keeps its figures instead of flipping to a placeholder and back on every transient
    /// failure.
    func testKeepsTheLastKnownFiguresThroughAFailedRefresh() {
        XCTAssertEqual(
            lifetime(stats: makeStats(), statsFailed: true, entries: [makeEntry()]),
            .figures(makeStats())
        )
    }

    func testOnlySaysEmptyWhenTheSummaryItselfAnsweredZero() {
        XCTAssertEqual(
            lifetime(stats: makeStats(totalPrints: 0, successfulPrints: 0), entries: []),
            .empty
        )
        // A summary with no count in it is not a summary saying zero.
        XCTAssertEqual(
            lifetime(stats: makeStats(totalPrints: nil), entries: []),
            .unavailable(.answeredWithoutOne)
        )
    }

    /// The corroboration this card needs is "will I contradict the table beside me?", NOT "did the
    /// archive list request succeed?".
    ///
    /// A cold archive failure leaves `entries == []` and renders NOTHING below (the History block's
    /// `.unknown`), so there is no list for "No prints archived yet" to contradict — and the
    /// summary answering zero is the authority on the question anyway. Reading `historyFailed`
    /// directly suppressed a true "empty" whenever the unrelated list request happened to fail.
    func testRepeatsTheSummarysZeroWhenNothingOnScreenContradictsIt() {
        XCTAssertEqual(
            lifetime(stats: makeStats(totalPrints: 0, successfulPrints: 0), entries: [], historyFailed: true),
            .empty
        )
        // But never above visible archived runs: server figures that disagree with the rows are
        // not a lifetime total this card can stand behind.
        XCTAssertEqual(
            lifetime(stats: makeStats(totalPrints: 0, successfulPrints: 0), entries: [makeEntry()]),
            .unavailable(.answeredWithoutOne)
        )
    }

    func testSpinsOnlyWhileTheSummaryHasNotBeenAskedYet() {
        // Cold launch, and the same state `JobsStore.attach` resets to on a session swap.
        XCTAssertEqual(lifetime(stats: nil, statsAsked: false, entries: nil), .loading)
        XCTAssertEqual(lifetime(stats: nil, statsAsked: true, entries: nil), .unavailable(.answeredWithoutOne))
    }

    /// The two reasons exist to be told apart in words; identical help text would make the split
    /// pointless, and one sentence for both is what asserted "it didn't answer" about a summary
    /// that had.
    func testTheTwoReasonsExplainThemselvesDifferently() {
        XCTAssertNotEqual(
            MacJobsLifetimeBody.NoTotal.requestFailed.help,
            MacJobsLifetimeBody.NoTotal.answeredWithoutOne.help
        )
        XCTAssertTrue(MacJobsLifetimeBody.NoTotal.requestFailed.help.contains("didn't answer"))
        XCTAssertFalse(MacJobsLifetimeBody.NoTotal.answeredWithoutOne.help.contains("didn't answer"))
    }
}

// MARK: - The UP NEXT heading

final class MacJobsQueueHeaderTests: XCTestCase {

    /// **The regression.** A cold queue failure renders a retry banner and a deliberately BLANK
    /// body, because we do not know what is queued — and the heading printed `UP NEXT · 0` directly
    /// above it, asserting the empty lane `content` had just refused to assert.
    func testShowsNoCountWhileTheQueueIsUnknown() {
        XCTAssertEqual(MacJobsQueueBody.unknown.headerLabel(count: 0), "UP NEXT")
        XCTAssertEqual(MacJobsQueueBody.loading.headerLabel(count: 0), "UP NEXT")
    }

    /// End to end from the store's own failure shape: `loadQueue` falls back to `queue ?? []`, so
    /// the count computed from it is a truthful `0` about an array nobody was ever sent.
    func testTheCountIsSuppressedForTheStoresOwnColdFailureState() {
        let state = MacJobsQueueBody.of(queue: [], failed: true, printerId: 1)
        let lane = JobsStore.upNext([], printerId: 1)
        XCTAssertEqual(lane.count, 0)
        XCTAssertEqual(state.headerLabel(count: lane.count), "UP NEXT")
    }

    func testCountsWhatTheBlockIsActuallyShowing() {
        XCTAssertEqual(MacJobsQueueBody.rows.headerLabel(count: 3), "UP NEXT · 3")
        XCTAssertEqual(MacJobsQueueBody.rows.headerLabel(count: 1), "UP NEXT · 1")
    }

    /// The placeholder card underneath says "Nothing queued…" in words; `· 0` on top of it is the
    /// same fact told twice, which is why iOS omits the whole header there.
    func testDropsTheCountWhenAPlaceholderAlreadySaysItInWords() {
        XCTAssertEqual(MacJobsQueueBody.emptyEverywhere.headerLabel(count: 0), "UP NEXT")
        XCTAssertEqual(MacJobsQueueBody.elsewhereOnly.headerLabel(count: 0), "UP NEXT")
    }
}

// MARK: - Command outcomes

final class MacJobsToastTests: XCTestCase {

    /// Reads like every other Mac command failure — `AppModel.perform` writes
    /// "Pause failed — AMS is busy" — and keeps Bambuddy's own words, which a 409 puts in `detail`.
    func testJoinsTheAlertsTwoHalvesIntoOneLine() {
        XCTAssertEqual(
            MacJobsToast.text(JobActionMessage.failed("Couldn’t remove", "AMS is busy")),
            "Couldn’t remove — AMS is busy"
        )
        XCTAssertEqual(
            MacJobsToast.text(JobActionMessage.ok("Queued", "The job is back in the queue.")),
            "Queued — The job is back in the queue."
        )
    }

    /// Neither half may be dropped when it is the only one there — a toast reading " — " or a bare
    /// dash is worse than either sentence alone.
    func testNeverRendersALoneSeparator() {
        XCTAssertEqual(MacJobsToast.text(JobActionMessage.failed("", "AMS is busy")), "AMS is busy")
        XCTAssertEqual(MacJobsToast.text(JobActionMessage.failed("Couldn’t reprint", "")), "Couldn’t reprint")
        XCTAssertEqual(MacJobsToast.text(JobActionMessage.failed("  ", " \n")), "")
        XCTAssertEqual(
            MacJobsToast.text(JobActionMessage.failed(" Couldn’t reprint ", " 409 ")),
            "Couldn’t reprint — 409"
        )
    }
}

// MARK: - The empty inspector

final class MacJobsInspectorPlaceholderTests: XCTestCase {

    private func place(
        selectedId: Int?,
        entries: [PrintLogEntry]?,
        historyFailed: Bool = false
    ) -> MacJobsInspectorPlaceholder {
        MacJobsInspectorPlaceholder.of(selectedId: selectedId, entries: entries, historyFailed: historyFailed)
    }

    /// **The regression.** `entries != nil` answers "has the array been assigned?"; `loadHistory`
    /// falls back to `entries = entries ?? []`, so a cold failure assigns a non-nil array that was
    /// never read from the server. `selectedId` is restored from `@SceneStorage` before anything
    /// loads, so the first frame after a failed fetch told the user their run had aged out of an
    /// archive the app had never managed to read.
    func testNeverClaimsARunAgedOutOfAnArchiveItCouldNotRead() {
        XCTAssertEqual(place(selectedId: 7, entries: [], historyFailed: true), .archiveUnread)
        XCTAssertEqual(place(selectedId: 7, entries: nil, historyFailed: true), .archiveUnread)
    }

    func testSpinsRatherThanAccusingWhileTheArchiveHasNotAnsweredYet() {
        XCTAssertEqual(place(selectedId: 7, entries: nil), .archiveLoading)
    }

    /// The claim is licensed only once the archive HAS answered and the run is not in what it sent.
    func testSaysAgedOutOnlyOnceTheArchiveAnsweredWithoutTheRun() {
        XCTAssertEqual(place(selectedId: 7, entries: [makeEntry(id: 9)]), .selectionAgedOut)
        XCTAssertEqual(place(selectedId: 7, entries: []), .selectionAgedOut)
    }

    func testHoldsNoOpinionWhenNothingWasEverSelected() {
        XCTAssertEqual(place(selectedId: nil, entries: nil), .nothingSelected)
        XCTAssertEqual(place(selectedId: nil, entries: [], historyFailed: true), .nothingSelected)
        XCTAssertEqual(place(selectedId: nil, entries: [makeEntry()]), .nothingSelected)
    }

    /// "No run selected" is true in exactly one of the four, and the other three DO hold a
    /// selection — a title saying otherwise contradicted the hint printed under it.
    func testOnlyTheUnselectedStateSaysNoRunSelected() {
        XCTAssertEqual(MacJobsInspectorPlaceholder.nothingSelected.title, "No run selected")
        for state: MacJobsInspectorPlaceholder in [.archiveLoading, .archiveUnread, .selectionAgedOut] {
            XCTAssertNotEqual(state.title, "No run selected")
            XCTAssertFalse(state.hint.isEmpty)
        }
    }

    /// A clock-with-an-arrow over "Archive not loaded" reads as "still working on it", which is the
    /// one thing that state is not; it borrows the retry banner's glyph instead.
    func testTheFailedStateDoesNotWearALoadingGlyph() {
        XCTAssertEqual(MacJobsInspectorPlaceholder.archiveUnread.symbol, "wifi.slash")
        XCTAssertEqual(MacJobsInspectorPlaceholder.archiveLoading.symbol, "clock.arrow.circlepath")
        XCTAssertEqual(MacJobsInspectorPlaceholder.nothingSelected.symbol, "clock.arrow.circlepath")
    }
}
#endif

/// The toast's KIND comes from the outcome, never from the copy.
///
/// `JobActionMessage` carried no success flag, so `MacJobsToast` had nothing to decide on and every
/// message went through the failure banner — putting a warning triangle over "Queued — the job is
/// back in the queue".
#if os(macOS)
final class MacJobsToastKindTests: XCTestCase {

    func testASuccessIsNotDressedAsAFailure() {
        let toast = MacJobsToast.toast(.ok("Queued", "The job is back in the queue."))
        XCTAssertEqual(toast.kind, .success)
        XCTAssertEqual(toast.text, "Queued — The job is back in the queue.")
    }

    func testAFailureStaysAFailure() {
        let toast = MacJobsToast.toast(.failed("Couldn’t remove", "AMS is busy"))
        XCTAssertEqual(toast.kind, .failure)
    }

    /// The kind is read off the flag, not inferred from words. A refusal whose copy happens to read
    /// cheerfully is still a refusal.
    func testTheKindDoesNotDependOnTheWording() {
        XCTAssertEqual(MacJobsToast.toast(.failed("Queued", "…actually it wasn’t")).kind, .failure)
        XCTAssertEqual(MacJobsToast.toast(.ok("Couldn’t", "…but it did")).kind, .success)
    }
}
#endif

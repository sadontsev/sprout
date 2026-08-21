import XCTest
@testable import Sprout

// The pure rules behind the redesigned Live Activity surfaces.
//
// Everything here renders on a lock screen, in a separate process, while nobody is looking at it —
// which is exactly why these are unit tests rather than something to eyeball. A card that is wrong
// for two seconds during a ten-hour print is never seen and never reported.

// MARK: - The state ladder

/// One ordered ladder, read by the iOS card's tint and the Mac menu bar's glyph.
final class LAStateTests: XCTestCase {

    private func vm(_ kind: DashKind, paused: Bool = false, color: StateColor = .running) -> DashVM {
        var v = DashVM()
        v.kind = kind
        v.isPaused = paused
        v.stateColor = color
        return v
    }

    /// The order is the content. Error outranks everything — including a paused print that is also
    /// failing, which is the case where reading these as independent conditions goes wrong.
    func testErrorOutranksPaused() {
        XCTAssertEqual(LAState.of(vm: vm(.error, paused: true)), .error)
    }

    /// `DashKind` has no `paused` case at all — pause is `isPaused` — so a live-and-paused print must
    /// not report as printing. This is the exact mistake a hand-rolled switch over `kind` makes, and
    /// pause is the one state a status surface exists to make obvious.
    func testAPausedLivePrintIsPausedAndNotPrinting() {
        XCTAssertEqual(LAState.of(vm: vm(.live, paused: true)), .paused)
        XCTAssertEqual(LAState.of(vm: vm(.live)), .printing)
    }

    func testHeatingIsReadFromTheStateColourNotTheKind() {
        XCTAssertEqual(LAState.of(vm: vm(.live, color: .heating)), .heating)
    }

    /// Drying is not a `DashKind`: it runs alongside whatever else is happening, so it can only be
    /// the answer when nothing else is. A print outranks it — the print has the deadline.
    func testDryingOnlyWinsOnAnIdleMachine() {
        XCTAssertEqual(LAState.of(vm: vm(.idle), drying: true), .drying)
        XCTAssertEqual(LAState.of(vm: vm(.live), drying: true), .printing)
        XCTAssertEqual(LAState.of(vm: vm(.error), drying: true), .error)
        XCTAssertEqual(LAState.of(vm: vm(.idle)), .idle)
    }

    func testConnectingReadsAsOfflineRatherThanIdle() {
        XCTAssertEqual(LAState.of(vm: vm(.connecting)), .offline)
        XCTAssertEqual(LAState.of(vm: vm(.offline)), .offline)
    }

    /// A finished print keeps the running green deliberately — it is a good outcome, and the card
    /// stays up until the plate is cleared. Pinned because it looks like an oversight.
    func testCompleteKeepsTheRunningGreen() {
        XCTAssertEqual(LAState.of(vm: vm(.complete)), .complete)
        XCTAssertEqual(LAState.of(vm: vm(.complete)).tintHex, LAColors.running)
    }

    /// Every state resolves to a colour Trellis also sends. A tint the server never produces would
    /// make a locally-started card a different colour from the identical pushed one.
    func testEveryTintIsOneTheServerAlsoSends() {
        let wire = Set([LAColors.running, LAColors.heating, LAColors.paused,
                        LAColors.error, LAColors.idle, LAColors.drying])
        for state in LAState.allCases {
            XCTAssertTrue(wire.contains(state.tintHex), "\(state) -> \(state.tintHex)")
        }
    }
}

// MARK: - The extrusion bar

final class ExtrusionRiderTests: XCTestCase {

    /// The whole reason the clamp exists: at 3 % the glyph's centre would sit 3 % along and most of
    /// the nozzle would hang off the rounded cap into nothing.
    func testTheGlyphNeverHangsOffEitherEnd() {
        let width: CGFloat = 200
        let glyph: CGFloat = 15
        XCTAssertEqual(ExtrusionRider.centreX(progress: 0, width: width, glyphWidth: glyph), glyph / 2)
        XCTAssertEqual(ExtrusionRider.centreX(progress: 0.03, width: width, glyphWidth: glyph), glyph / 2)
        XCTAssertEqual(ExtrusionRider.centreX(progress: 1, width: width, glyphWidth: glyph), width - glyph / 2)
    }

    func testTheMiddleIsUntouched() {
        XCTAssertEqual(ExtrusionRider.centreX(progress: 0.5, width: 200, glyphWidth: 15), 100)
    }

    /// Progress comes off the wire from Trellis, so it is clamped rather than trusted. A NaN would
    /// otherwise propagate into a frame offset and blank the whole card.
    func testWireGarbageIsClamped() {
        for bad in [-1.0, 2.0, Double.nan, .infinity, -.infinity] {
            let x = ExtrusionRider.centreX(progress: bad, width: 200, glyphWidth: 15)
            XCTAssertTrue(x.isFinite, "\(bad)")
            XCTAssertGreaterThanOrEqual(x, 7.5)
            XCTAssertLessThanOrEqual(x, 192.5)
        }
    }

    /// A glyph wider than its bar cannot satisfy both bounds. It centres rather than letting the
    /// lower bound win and pinning it hard left, which would read as a stuck print.
    func testAGlyphWiderThanTheBarCentres() {
        XCTAssertEqual(ExtrusionRider.centreX(progress: 0.9, width: 10, glyphWidth: 15), 5)
    }

    func testAZeroWidthBarDoesNotDivideByIt() {
        XCTAssertEqual(ExtrusionRider.centreX(progress: 0.5, width: 0, glyphWidth: 15), 0)
    }

    /// **Only while something is actually extruding.** A parked nozzle drawn mid-bar on a paused or
    /// failed print says the machine is still laying plastic — a lie told by a decoration, in exactly
    /// the states someone is anxiously checking.
    func testTheNozzleRidesOnlyWhileExtruding() {
        XCTAssertTrue(ExtrusionRider.rides(tintHex: LAColors.running, finished: false))
        XCTAssertTrue(ExtrusionRider.rides(tintHex: LAColors.heating, finished: false))
        XCTAssertFalse(ExtrusionRider.rides(tintHex: LAColors.paused, finished: false))
        XCTAssertFalse(ExtrusionRider.rides(tintHex: LAColors.error, finished: false))
        XCTAssertFalse(ExtrusionRider.rides(tintHex: LAColors.idle, finished: false))
        XCTAssertFalse(ExtrusionRider.rides(tintHex: LAColors.drying, finished: false))
    }

    /// **The tint alone cannot answer this**, which is why `finished` is a parameter.
    /// `LAState.complete.tintHex` IS `LAColors.running` — the same green — and Trellis sends that hex
    /// for FINISH/FINISHED/FINISHING. A tint-only predicate parked the nozzle at the end of a full bar
    /// on a completed print and told the user the machine was still laying plastic.
    func testAFinishedPrintDoesNotExtrude() {
        XCTAssertEqual(LAState.complete.tintHex, LAColors.running, "the premise of this test")
        XCTAssertFalse(ExtrusionRider.rides(tintHex: LAColors.running, finished: true))
        XCTAssertFalse(ExtrusionRider.rides(tintHex: LAColors.heating, finished: true))
    }

    /// Case-insensitive, because the hex arrives as a string off the wire and nothing guarantees the
    /// server's casing matches the constant's.
    func testTheTintComparisonIgnoresCase() {
        XCTAssertTrue(ExtrusionRider.rides(tintHex: LAColors.running.lowercased(), finished: false))
        XCTAssertTrue(ExtrusionRider.rides(tintHex: LAColors.running.uppercased(), finished: false))
    }

    func testAnUnknownTintDoesNotRide() {
        XCTAssertFalse(ExtrusionRider.rides(tintHex: "#123456", finished: false))
        XCTAssertFalse(ExtrusionRider.rides(tintHex: "", finished: false))
    }
}

// MARK: - The drying mark

final class SpoolMarkTests: XCTestCase {

    /// Heavier as it gets SMALLER, which is the opposite of scaling — a 1.8 pt stroke scaled with the
    /// artwork lands under a point at 14 pt and the ring vanishes. It has to survive to 14 because
    /// that is the Mac menu bar.
    func testTheStrokeGetsHeavierAsTheMarkGetsSmaller() {
        XCTAssertEqual(SpoolMark.strokeWidth(forSize: 56), 1.8)
        XCTAssertEqual(SpoolMark.strokeWidth(forSize: 34), 1.8)
        XCTAssertEqual(SpoolMark.strokeWidth(forSize: 21), 2.1)
        XCTAssertEqual(SpoolMark.strokeWidth(forSize: 17), 2.1)
        XCTAssertEqual(SpoolMark.strokeWidth(forSize: 14), 2.3)
        XCTAssertEqual(SpoolMark.strokeWidth(forSize: 10), 2.3)
    }

    /// Monotonic: no size may get a lighter stroke than a larger one.
    func testWeightNeverIncreasesWithSize() {
        var last = SpoolMark.strokeWidth(forSize: 8)
        for size in stride(from: 8.0, through: 80.0, by: 1) {
            let w = SpoolMark.strokeWidth(forSize: size)
            XCTAssertLessThanOrEqual(w, last, "\(size)")
            last = w
        }
    }
}

// MARK: - App Group art

final class LiveActivityArtTests: XCTestCase {

    /// **Stable across processes.** `hashValue` is seeded per process, so the app and the widget
    /// would compute different names for the same file and the app a different one every launch —
    /// the card would flicker between a fresh write and a missing file.
    func testTheHashIsStableAcrossCalls() {
        XCTAssertEqual(LiveActivityArt.stableHash("planter-lattice.gcode.3mf"),
                       LiveActivityArt.stableHash("planter-lattice.gcode.3mf"))
        XCTAssertNotEqual(LiveActivityArt.stableHash("a"), LiveActivityArt.stableHash("b"))
    }

    /// A known digest, so a "harmless" change to the hash function fails here rather than silently
    /// orphaning every already-written plate.
    func testTheHashIsPinned() {
        XCTAssertEqual(LiveActivityArt.stableHash(""), String(UInt64(0xcbf2_9ce4_8422_2325), radix: 36))
    }

    /// Two printers running produce two cards. Naming the plate by printer alone means the second
    /// write overwrites the first and both cards show the same model.
    func testTwoPrintersDoNotShareAPlateFile() {
        let a = LiveActivityArt.plateName(printerId: 1, fileName: "cube.gcode.3mf")
        let b = LiveActivityArt.plateName(printerId: 2, fileName: "cube.gcode.3mf")
        XCTAssertNotEqual(a, b)
    }

    /// A new job on the same printer writes to a new path, so a card cannot show the previous
    /// print's plate while the new thumbnail downloads.
    func testANewJobGetsANewPath() {
        let a = LiveActivityArt.plateName(printerId: 1, fileName: "cube.gcode.3mf")
        let b = LiveActivityArt.plateName(printerId: 1, fileName: "bracket.gcode.3mf")
        XCTAssertNotEqual(a, b)
    }

    /// The sweep keys on this prefix, so every plate must carry it or the container grows forever.
    func testPlatesAreSweepable() {
        XCTAssertTrue(LiveActivityArt.plateName(printerId: 9, fileName: "x").hasPrefix("plate-"))
        XCTAssertFalse(LiveActivityArt.glyphName.hasPrefix("plate-"))
    }

    /// Must equal the entitlements. A mismatch yields no container, so every card silently loses its
    /// artwork — the failure this whole type exists to end.
    func testTheGroupIdMatchesTheEntitlements() {
        XCTAssertEqual(LiveActivityArt.groupId, "group.com.mvks5.bambu")
    }
}

// MARK: - Matching a job to its picture

final class PrintArtTests: XCTestCase {

    private func file(_ id: Int, _ filename: String, printName: String? = nil, thumb: String? = "/t.png") -> LibraryFile {
        var f = LibraryFile(id: id, filename: filename)
        f.printName = printName
        f.thumbnailPath = thumb
        return f
    }

    /// The printer drops the extension; the library keeps the slicer's output name.
    func testTheStemSurvivesEverySpelling() {
        XCTAssertEqual(PrintArt.stem("planter-lattice.gcode.3mf"), "planter-lattice")
        XCTAssertEqual(PrintArt.stem("planter-lattice"), "planter-lattice")
        XCTAssertEqual(PrintArt.stem("Planter-Lattice.3MF"), "planter-lattice")
        XCTAssertEqual(PrintArt.stem("Adapter%20hexagon.stl"), "adapter hexagon")
    }

    /// `.gcode.3mf` must not be read as `.3mf` with a leftover `.gcode`.
    func testTheLongestExtensionWins() {
        XCTAssertEqual(PrintArt.stem("cube.gcode.3mf"), "cube")
    }

    func testAJobMatchesItsLibraryRow() {
        let library = [file(1, "cube.gcode.3mf"), file(2, "bracket.3mf")]
        XCTAssertEqual(PrintArt.match(jobName: "cube", in: library)?.id, 1)
        XCTAssertEqual(PrintArt.match(jobName: "bracket.3mf", in: library)?.id, 2)
    }

    /// **Exact stems only.** A prefix match would put one model's render on another's card — worse
    /// than showing none, because the fallback is an honest brand glyph.
    func testAPrefixIsNotAMatch() {
        let library = [file(1, "benchy.3mf"), file(2, "benchy v2.3mf")]
        XCTAssertNil(PrintArt.match(jobName: "benchy v", in: library))
        XCTAssertEqual(PrintArt.match(jobName: "benchy", in: library)?.id, 1)
    }

    /// Re-uploading is the ordinary way a name repeats, and the newest is the one just printed.
    func testTheNewestDuplicateWins() {
        let library = [file(3, "cube.3mf"), file(9, "cube.3mf"), file(5, "cube.3mf")]
        XCTAssertEqual(PrintArt.match(jobName: "cube", in: library)?.id, 9)
    }

    /// A row with no thumbnail cannot supply a picture, so it must not win the match and suppress a
    /// sibling that could.
    func testARowWithNoThumbnailIsNotAMatch() {
        let library = [file(9, "cube.3mf", thumb: nil), file(3, "cube.3mf")]
        XCTAssertEqual(PrintArt.match(jobName: "cube", in: library)?.id, 3)
    }

    func testPrintNameIsMatchedToo() {
        let library = [file(1, "upload-xyz.3mf", printName: "Planter Lattice")]
        XCTAssertEqual(PrintArt.match(jobName: "Planter Lattice", in: library)?.id, 1)
    }

    func testAnEmptyJobNameMatchesNothing() {
        XCTAssertNil(PrintArt.match(jobName: "", in: [file(1, "cube.3mf")]))
        XCTAssertNil(PrintArt.match(jobName: "   ", in: [file(1, "cube.3mf")]))
    }

    /// The art borrows the SOURCE model's render when the printed file is a slice, reusing
    /// `ThumbSource` so the card and the Files grid cannot disagree about which picture is the print.
    func testTheArtBorrowsTheSourceModelsRender() {
        let library = [file(10, "cube.3mf"), file(11, "cube.gcode.3mf")]
        XCTAssertEqual(PrintArt.artFile(jobName: "cube.gcode.3mf", in: library)?.id, 10)
    }

    /// The rung that actually fires for most prints. Measured on the live machine: the running job
    /// `kid34_slide_A_76` matched NO library row, and sat on the printer's card as
    /// `kid34_slide_A_76.gcode.3mf`.
    func testTheRunningJobIsFoundOnTheCard() {
        let card = [
            PrinterFile(name: "02_basket.gcode.3mf", isDirectory: false, size: nil, path: "/02_basket.gcode.3mf", mtime: nil),
            PrinterFile(name: "kid34_slide_A_76.gcode.3mf", isDirectory: false, size: nil, path: "/kid34_slide_A_76.gcode.3mf", mtime: nil),
        ]
        XCTAssertEqual(PrintArt.matchSd(jobName: "kid34_slide_A_76", in: card)?.path,
                       "/kid34_slide_A_76.gcode.3mf")
    }

    /// A folder never supplies a plate, even one named like the job.
    func testAFolderOnTheCardIsNotAMatch() {
        let card = [PrinterFile(name: "cube", isDirectory: true, size: nil, path: "/cube", mtime: nil)]
        XCTAssertNil(PrintArt.matchSd(jobName: "cube", in: card))
    }

    /// Exact stems on the card too — a near-match puts the wrong model on the lock screen.
    func testTheCardMatchIsExact() {
        let card = [PrinterFile(name: "kid34_slide_B_76.gcode.3mf", isDirectory: false, size: nil,
                                path: "/kid34_slide_B_76.gcode.3mf", mtime: nil)]
        XCTAssertNil(PrintArt.matchSd(jobName: "kid34_slide_A_76", in: card))
    }

    func testAnUnmatchedJobHasNoArt() {
        XCTAssertNil(PrintArt.artFile(jobName: "nothing", in: [file(1, "cube.3mf")]))
    }

    // MARK: - When the card is worth listing again

    private func sd(_ names: [String]) -> [PrinterFile] {
        names.map { PrinterFile(name: $0, isDirectory: false, size: nil, path: "/" + $0, mtime: nil) }
    }

    /// The listing we already hold answers the question — no request, however many times the
    /// 4-second loop asks.
    func testACardListingThatAlreadyHasTheJobIsNotRelisted() {
        XCTAssertFalse(PrintArt.shouldListCard(job: "cube", browsed: sd(["cube.gcode.3mf"]),
                                               cached: nil, alreadyAsked: false))
        XCTAssertFalse(PrintArt.shouldListCard(job: "cube", browsed: [],
                                               cached: sd(["cube.gcode.3mf"]), alreadyAsked: false))
    }

    /// The case the whole rule exists for: a print sent from Studio lands on the card AFTER the app
    /// cached the listing. Keyed by printer alone, that job is never looked for again and the card
    /// shows a glyph for the rest of the session.
    func testAJobMissingFromACachedListingEarnsOneRelist() {
        XCTAssertTrue(PrintArt.shouldListCard(job: "duct_clamp", browsed: [],
                                              cached: sd(["something_else.gcode.3mf"]),
                                              alreadyAsked: false))
    }

    /// An empty listing is the unreachable-printer case, and must not become a permanent answer —
    /// but it still only costs one request.
    func testAnEmptyCachedListingIsAskedOncePerJob() {
        XCTAssertTrue(PrintArt.shouldListCard(job: "duct_clamp", browsed: [], cached: [],
                                              alreadyAsked: false))
        XCTAssertFalse(PrintArt.shouldListCard(job: "duct_clamp", browsed: [], cached: [],
                                               alreadyAsked: true))
    }

    /// Having asked for THIS job says nothing about the next one — that is the point of keying the
    /// memo by job rather than by printer.
    func testTheMemoDoesNotCarryToTheNextJob() {
        // `alreadyAsked` is the caller's per-job lookup, so a different job arrives as false.
        XCTAssertTrue(PrintArt.shouldListCard(job: "next_print", browsed: [],
                                              cached: sd(["duct_clamp.gcode.3mf"]),
                                              alreadyAsked: false))
    }

    /// A browsed listing that has the job wins even when it has been asked before — the answer is
    /// already in hand, so "have we asked?" never gets a say.
    func testAMatchBeatsTheAskedMemo() {
        XCTAssertFalse(PrintArt.shouldListCard(job: "cube", browsed: sd(["cube.gcode.3mf"]),
                                               cached: [], alreadyAsked: true))
    }
}

#if os(macOS)

// MARK: - Mac status marks

final class MacStatusMarkTests: XCTestCase {

    /// Every ladder state has a mark. A missing case would fall back to the bare nozzle, which is the
    /// undifferentiated glyph this whole type exists to replace.
    func testEveryStateHasItsOwnMark() {
        let marks = LAState.allCases.map { MacStatusMark.mark($0) }
        XCTAssertEqual(Set(marks).count, LAState.allCases.count)
    }

    /// Printing shows a percentage instead of a glyph — and it is the ONLY state that does, because
    /// mixing an image and text makes the item's width jump whenever a print starts.
    func testOnlyPrintingReplacesTheGlyphWithANumber() {
        for mark in MacStatusMark.allCases {
            XCTAssertEqual(mark.showsGlyph, mark != .printing, "\(mark)")
        }
    }

    /// Present-but-doing-nothing is said with ink, not colour, because these are template images.
    func testIdleAndOfflineAreDimmedAndNothingElseIs() {
        XCTAssertEqual(MacStatusMark.idle.inkOpacity, 0.55)
        XCTAssertEqual(MacStatusMark.offline.inkOpacity, 0.38)
        XCTAssertLessThan(MacStatusMark.offline.inkOpacity, MacStatusMark.idle.inkOpacity)
        for mark in MacStatusMark.allCases where mark != .idle && mark != .offline {
            XCTAssertEqual(mark.inkOpacity, 1.0, "\(mark)")
        }
    }

    /// **Exactly one colour exception in the whole menu bar.** Error is the state that must not be
    /// missed, and a monochrome exclam among monochrome neighbours is what gets missed.
    func testErrorIsTheOnlyMarkWithColour() {
        for mark in MacStatusMark.allCases {
            XCTAssertEqual(mark.pip != nil, mark == .error, "\(mark)")
        }
    }
}
#endif


#if os(iOS)
// MARK: - Aggregate drying
//
// iOS-only: `LiveActivityController` and `PrintActivityAttributes` are both `#if os(iOS)` because
// ActivityKit does not exist on macOS. A smaller iOS count is a regression; a smaller macOS one is
// not — see CLAUDE.md.

/// Two or more drying units collapse into one card.
///
/// Three drying-capable units are fitted, so one card each PLUS the print card is four cards for a
/// single machine — and iOS orders the lock-screen stack by start time, which is not controllable.
/// The only lever is how many cards exist.
final class AggregateDryingTests: XCTestCase {

    private func unit(_ id: Int, mins: Double, temp: Double = 50, target: Double = 65,
                      humidity: Double = 24, filament: String = "PETG", ht: Bool = false) -> AmsUnitRaw {
        var u = AmsUnitRaw(id: id)
        u.dryTime = LooseNumber(mins)
        u.temp = LooseNumber(temp)
        u.dryTargetTemp = LooseNumber(target)
        u.humidity = LooseNumber(humidity)
        u.dryFilament = filament
        u.isAmsHt = ht
        return u
    }

    private func status(_ units: [AmsUnitRaw]) -> PrinterStatus {
        var s = PrinterStatus()
        s.ams = units
        return s
    }

    /// An aggregate of one is a worse version of the card it replaces.
    func testOneUnitKeepsItsOwnCard() {
        XCTAssertNil(LiveActivityController.aggregateDryContent(status([unit(0, mins: 120)])))
    }

    func testTwoUnitsCollapse() {
        let got = LiveActivityController.aggregateDryContent(status([unit(0, mins: 120), unit(1, mins: 45)]))
        XCTAssertEqual(got?.dryUnits?.count, 2)
        XCTAssertEqual(got?.dry, true)
    }

    /// Soonest first — the rows answer "which finishes next".
    func testRowsSortSoonestFirst() {
        let got = LiveActivityController.aggregateDryContent(
            status([unit(0, mins: 300), unit(1, mins: 45), unit(2, mins: 120)]))
        XCTAssertEqual(got?.dryUnits?.map(\.minutesLeft), [45, 120, 300])
    }

    /// The HEADLINE is the longest — the header answers "when is the whole batch done", which is a
    /// different question from the one the rows answer.
    func testTheHeadlineIsTheLongest() {
        let now = Date()
        let got = LiveActivityController.aggregateDryContent(
            status([unit(0, mins: 300), unit(1, mins: 45)]), now: now)
        let minutes = ((got?.etaEpochMs ?? 0) / 1000 - now.timeIntervalSince1970) / 60
        XCTAssertEqual(minutes, 300, accuracy: 1)
    }

    func testIdleUnitsAreNotRows() {
        let got = LiveActivityController.aggregateDryContent(
            status([unit(0, mins: 120), unit(1, mins: 0), unit(2, mins: 45)]))
        XCTAssertEqual(Set(got?.dryUnits?.map(\.amsId) ?? []), [0, 2])
    }

    /// The HT is not "AMS 3" — it has its own label, which is why the row carries one rather than
    /// deriving it from the index.
    func testTheHtIsNotAmsThree() {
        let got = LiveActivityController.aggregateDryContent(
            status([unit(0, mins: 120), unit(128, mins: 45, ht: true)]))
        XCTAssertEqual(Set(got?.dryUnits?.map(\.label) ?? []), ["AMS 1", "AMS HT"])
    }

    /// Unit ids are indices, so a negative sentinel can never collide — an aggregate that took a
    /// real unit's identity would replace that unit's own card.
    func testTheSentinelCannotBeARealUnitId() {
        XCTAssertLessThan(PrintActivityAttributes.aggregateAmsId, 0)
    }

    /// **A new field is invisible until it is in `meaningfulChange`.** Every push is gated on that
    /// comparison, so rows whose temperatures moved while nothing else did would never reach the card.
    func testRowChangesAreWorthAPush() {
        var a = PrintActivityAttributes.ContentState()
        a.dryUnits = [PrintActivityAttributes.DryUnitState(amsId: 0, temp: 50)]
        var b = a
        b.dryUnits = [PrintActivityAttributes.DryUnitState(amsId: 0, temp: 58)]
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: b))
    }

    /// Single-unit cards keep the flat fields, so a Trellis that has not been redeployed renders
    /// exactly what it did before rather than a blank card.
    func testASingleUnitCardCarriesNoRows() {
        let got = LiveActivityController.dryContent(status([unit(0, mins: 120)]), amsId: 0)
        XCTAssertNil(got?.dryUnits)
        XCTAssertEqual(got?.amsTemp, 50)
    }
}
#endif

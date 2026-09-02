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

    // MARK: - The plate a push did not carry

    /// A remote update replaces the whole `ContentState`, and Trellis sends `modelUri: ""` on every
    /// one — it has no idea which plate the device wrote. So the widget must not read the pushed
    /// value alone, or the preview vanishes on the first server update after it appears.
    func testACarriedUriIsUsedWhenThePushHasOne() {
        XCTAssertEqual(
            LiveActivityArt.plateURI(printerId: 2, jobName: "duct_clamp", carried: "file:///x.png"),
            "file:///x.png")
    }

    /// With nothing carried, the path is DERIVED — from the printer id, which is a static attribute
    /// no push can touch, and the job name, which is the same `subtask_name` the plate was written
    /// under. Nothing on disk in the test container, so the answer is "", but the derivation is what
    /// matters: it must not crash and must not invent a URI.
    func testAnAbsentPlateIsEmptyRatherThanWrong() {
        XCTAssertEqual(
            LiveActivityArt.plateURI(printerId: 2, jobName: "never_printed_here", carried: ""),
            "")
    }

    /// No job name is no plate. Guarded because `plateName` would otherwise hash the empty string
    /// into a perfectly valid-looking filename shared by every printer with no job.
    func testAnEmptyJobNameHasNoPlate() {
        XCTAssertEqual(LiveActivityArt.plateURI(printerId: 2, jobName: "", carried: ""), "")
    }

    /// The derived name is what the resolver writes, or the two halves would never meet. Same
    /// function, asserted from both sides.
    func testTheDerivedNameMatchesWhatTheResolverWrites() {
        let written = LiveActivityArt.plateName(printerId: 7, fileName: "duct_clamp_H2C")
        XCTAssertEqual(
            written,
            "plate-7-\(LiveActivityArt.stableHash("duct_clamp_H2C"))-v\(LiveActivityArt.plateFormat).png")
        // Different printers never share a plate file, even for an identically named job.
        XCTAssertNotEqual(written, LiveActivityArt.plateName(printerId: 8, fileName: "duct_clamp_H2C"))
    }

    /// The name carries what the file CONTAINS, not just which job it is for.
    ///
    /// `plate()` returns an existing file untouched, so a plate written before `PlateGround` existed
    /// would stay ungrounded for the life of that print however many builds landed. The version in
    /// the name is what makes a changed rule look somewhere nothing has written yet — and it keeps
    /// the `plate-` prefix so the sweep still collects the old one.
    func testThePlateNameCarriesItsFormatVersion() {
        let name = LiveActivityArt.plateName(printerId: 2, fileName: "V2 Bins")
        XCTAssertTrue(name.hasSuffix("-v\(LiveActivityArt.plateFormat).png"), name)
        XCTAssertTrue(name.hasPrefix("plate-"), name)
        XCTAssertGreaterThanOrEqual(LiveActivityArt.plateFormat, 2)
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

    // MARK: - The plate the picture shows

    /// The SAME job re-run on a different plate is a different picture.
    ///
    /// The resolver keyed its in-memory cache on the job NAME alone, and the file it writes cannot
    /// carry a plate — the widget derives that name from `printerId` + `name` whenever Trellis
    /// blanks `modelUri`, and has no plate to derive with. So a second run of one file on another
    /// plate returned the first run's image. Reported live: plate 2 or 3 printing, plate 1 shown.
    func testAResolvedPlateIsIdentifiedByItsPlateNotOnlyItsJob() {
        let one = LiveActivityArtResolver.Resolved(jobName: "Beginner Set", plate: 1, modelUri: "a")
        let three = LiveActivityArtResolver.Resolved(jobName: "Beginner Set", plate: 3, modelUri: "b")
        XCTAssertNotEqual(one, three, "same job, different plate — not the same picture")
    }

    /// An unknown plate is its own identity, distinct from plate 1 — the whole point of `nil`.
    func testAnUnknownPlateIsNotPlateOne() {
        let unknown = LiveActivityArtResolver.Resolved(jobName: "x", plate: nil, modelUri: "a")
        let first = LiveActivityArtResolver.Resolved(jobName: "x", plate: 1, modelUri: "a")
        XCTAssertNotEqual(unknown, first)
    }

    // MARK: - A cover taken too early

    private func resolved(provisional: Bool) -> LiveActivityArtResolver.Resolved {
        LiveActivityArtResolver.Resolved(
            jobName: "Beginner Set", plate: 1, archiveId: 205, provisional: provisional,
            modelUri: "file:///old.png")
    }

    /// **The printer's cover can still be the PREVIOUS job's at layer 0.** Observed: a card created
    /// during "Auto bed leveling" showed the last print's model, while the same endpoint returned
    /// the right one minutes later. `coverAsked` then made that one early answer permanent — it
    /// exists to stop a 404 being retried every four seconds, not to freeze a wrong picture.
    func testAProvisionalCoverIsNotFinal() {
        XCTAssertTrue(resolved(provisional: true).provisional)
        XCTAssertFalse(
            resolved(provisional: false).provisional,
            "a cover taken after the first layer is the print's own")
    }

    /// Identity includes it, so a refreshed entry replaces the provisional one rather than being
    /// mistaken for it.
    func testAProvisionalEntryIsNotEqualToItsRefresh() {
        XCTAssertNotEqual(resolved(provisional: true), resolved(provisional: false))
    }

    // MARK: - One model, several plates, one file name

    /// **`subtask_name` is the MODEL's name and repeats across plates.** Measured on the live
    /// machine: "PLA profile + Optional PETG Translucent plate" is reported for plate 1 and for
    /// plate 4 alike. Keyed on that name alone, plate 4's card loaded the image plate 1 had
    /// written — the right file, the wrong model, and a real picture either way, which is why it
    /// read as working.
    func testTwoPlatesOfOneModelDoNotShareAFileName() {
        let job = "PLA profile + Optional PETG Translucent plate"
        let one = LiveActivityArt.plateName(printerId: 2, fileName: job, plate: 1)
        let four = LiveActivityArt.plateName(printerId: 2, fileName: job, plate: 4)
        XCTAssertNotEqual(one, four)
    }

    /// **The run id is the only key here that cannot repeat.** A slicer PRESET name — measured in
    /// the print history, "Best: 0.2mm layer, 2 walls, 15% infill" — repeats across unrelated
    /// models, so even name-plus-plate can collide. Two prints of the same plate of the same model
    /// got archive ids 203 and 204.
    func testTheRunIdOutranksTheNameAndPlate() {
        let job = "Best: 0.2mm layer, 2 walls, 15% infill"
        let a = LiveActivityArt.plateName(printerId: 2, fileName: job, plate: 1, archiveId: 203)
        let b = LiveActivityArt.plateName(printerId: 2, fileName: job, plate: 1, archiveId: 204)
        XCTAssertNotEqual(a, b, "same name, same plate, different RUN — different picture")
    }

    /// Each key is used only when the stronger one is absent, so a state never looks under a weaker
    /// name and finds another print's picture.
    func testTheKeyLadderFallsBackInOrder() {
        let job = "x"
        let withId = LiveActivityArt.plateName(printerId: 2, fileName: job, plate: 1, archiveId: 9)
        let withPlate = LiveActivityArt.plateName(printerId: 2, fileName: job, plate: 1)
        let bare = LiveActivityArt.plateName(printerId: 2, fileName: job)
        XCTAssertEqual(Set([withId, withPlate, bare]).count, 3, "three distinct keys")
        XCTAssertTrue(withId.contains("a9"), "the run id names it alone: \(withId)")
    }

    /// An unknown plate keeps the ORIGINAL name, so a card from an app or a Trellis that predates
    /// this field degrades to the old behaviour rather than to a miss.
    func testAnUnknownPlateKeepsTheOldName() {
        XCTAssertEqual(
            LiveActivityArt.plateName(printerId: 2, fileName: "x", plate: nil),
            LiveActivityArt.plateName(printerId: 2, fileName: "x"))
    }

    /// A `FileManager` whose App Group container is a temp directory, so the derivation can be
    /// exercised against real files. `directory(fileManager:)` takes one for exactly this reason.
    private final class ContainerStub: FileManager, @unchecked Sendable {
        let root: URL
        init(root: URL) {
            self.root = root
            super.init()
        }
        override func containerURL(forSecurityApplicationGroupIdentifier id: String) -> URL? { root }
    }

    /// The widget derives the path itself whenever a push blanks `modelUri`, so it must ask for the
    /// plate it is actually printing — not merely for the job.
    ///
    /// This is the reported failure, end to end: plate 1 printed earlier leaves its image behind,
    /// plate 4 starts, and the card drew plate 1's model.
    func testTheDerivedUriIsPlateSpecific() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = ContainerStub(root: root)
        let job = "PLA profile + Optional PETG Translucent plate"

        // Only plate 1's image exists — the state after printing plate 1 earlier.
        let dir = try XCTUnwrap(LiveActivityArt.directory(fileManager: fm))
        try Data([0x89]).write(
            to: dir.appendingPathComponent(
                LiveActivityArt.plateName(printerId: 2, fileName: job, plate: 1)))

        XCTAssertFalse(
            LiveActivityArt.plateURI(
                printerId: 2, jobName: job, plate: 1, carried: "", fileManager: fm).isEmpty,
            "plate 1 should find its own image")
        XCTAssertTrue(
            LiveActivityArt.plateURI(
                printerId: 2, jobName: job, plate: 4, carried: "", fileManager: fm).isEmpty,
            "plate 4 must NOT be handed plate 1's image — a glyph is honest, a wrong model is not")
        XCTAssertTrue(
            LiveActivityArt.plateURI(
                printerId: 2, jobName: job, plate: 1, archiveId: 204, carried: "", fileManager: fm)
                .isEmpty,
            "a state that knows its RUN must not fall back to a name that repeats")
    }

    // MARK: - The eight-hour duplicate

    private func card(_ id: String, _ identity: String, live: Bool) -> LiveActivityController.CardLiveness
    {
        LiveActivityController.CardLiveness(id: id, identity: identity, isLive: live)
    }

    /// The observed failure: a print past eight hours shows the frozen card beside its replacement.
    ///
    /// iOS ends a Live Activity at the eight-hour mark and its token starts answering APNs 410, but
    /// the card stays on the Lock Screen for up to four hours more. Trellis reads the 410 correctly
    /// and pushes a replacement; nothing but the app can clear the corpse.
    func testAnEndedCardIsRemovedWhenItsPrinterHasALiveOne() {
        let got = LiveActivityController.supersededCardIds([
            card("old", "print:2", live: false),
            card("new", "print:2", live: true),
        ])
        XCTAssertEqual(got, ["old"])
    }

    /// **The case that must not fire.** A finished print's card ends with nothing to replace it, and
    /// lingering is the entire point of the four hours. Ending on `.ended` alone would snatch every
    /// completed print off the Lock Screen the moment it finished.
    func testAnEndedCardWithNoReplacementIsLeftAlone() {
        XCTAssertEqual(LiveActivityController.supersededCardIds([card("done", "print:2", live: false)]), [])
    }

    /// A drying card and a print card are different identities, so one may not evict the other.
    func testALiveCardOnlySupersedesItsOwnPrinter() {
        let got = LiveActivityController.supersededCardIds([
            card("old-dry", "dry:2:0", live: false),
            card("live-print", "print:2", live: true),
        ])
        XCTAssertEqual(got, [], "a live PRINT card says nothing about a stale DRYING card")
    }

    /// Two printers past eight hours at once — each is cleared by its own replacement, not the
    /// other's.
    func testEachPrinterIsJudgedSeparately() {
        let got = LiveActivityController.supersededCardIds([
            card("old-2", "print:2", live: false),
            card("new-2", "print:2", live: true),
            card("old-3", "print:3", live: false),
        ])
        XCTAssertEqual(got, ["old-2"], "printer 3 has no live card, so its ended one stays")
    }

    /// Nothing to do in the ordinary case, which is every print under eight hours.
    func testASingleLiveCardIsUntouched() {
        XCTAssertEqual(LiveActivityController.supersededCardIds([card("a", "print:2", live: true)]), [])
    }

    // MARK: - Chamber (enclosed machines only)

    private func printStatus(chamber: Double?, chamberTarget: Double? = nil) -> PrinterStatus {
        var t = Temperatures()
        t.nozzle = 220
        t.bed = 60
        if let chamber { t.chamber = LooseNumber(chamber) }
        if let chamberTarget { t.chamberTarget = LooseNumber(chamberTarget) }
        var st = PrinterStatus()
        st.temperatures = t
        return st
    }

    /// An open-frame machine reports no `chamber` key, and the card must not invent one. A
    /// non-optional field defaulting to 0 would render a confident `C 0°` — this codebase's
    /// recurring bug, in the one surface the user cannot tap to correct.
    func testAnOpenFrameMachineCarriesNoChamber() {
        let got = LiveActivityController.content(vm: DashVM(), status: printStatus(chamber: nil))
        XCTAssertNil(got.chamber)
        XCTAssertNil(got.chamberTarget, "a target may never outlive the chamber it heats")
    }

    /// Presence, not value: a chamber genuinely reading 0° is still a chamber.
    func testAChamberReadingZeroIsStillAChamber() {
        let got = LiveActivityController.content(vm: DashVM(), status: printStatus(chamber: 0))
        XCTAssertEqual(got.chamber, 0)
    }

    func testAnEnclosedMachineCarriesChamberAndTarget() {
        let got = LiveActivityController.content(
            vm: DashVM(), status: printStatus(chamber: 31.4, chamberTarget: 50))
        XCTAssertEqual(got.chamber, 31)
        XCTAssertEqual(got.chamberTarget, 50)
    }

    /// The same predicate as the dashboard's, so the card and the temperature grid can never
    /// disagree about whether this printer has a chamber at all.
    func testTheCardAgreesWithTheDashboard() {
        for chamber in [nil, 0, 31] as [Double?] {
            let status = printStatus(chamber: chamber)
            var vm = DashVM()
            vm.hasChamber = status.temperatures?.chamber != nil
            let got = LiveActivityController.content(vm: vm, status: status)
            XCTAssertEqual(vm.hasChamber, got.chamber != nil, "chamber=\(String(describing: chamber))")
        }
    }

    /// **A new field is invisible until it is in `meaningfulChange`.** A chamber climbing through a
    /// soak while nothing else moves would otherwise never reach the card.
    func testChamberChangesAreWorthAPush() {
        var a = PrintActivityAttributes.ContentState()
        a.chamber = 31
        var b = a
        b.chamber = 40
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: b))

        var c = a
        c.chamberTarget = 50
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: c))
    }

    /// The whole feature rests on this decode, so it is pinned rather than reasoned about.
    ///
    /// `LooseNumber` has a custom `decodeNil()` branch that maps a JSON null to a LooseNumber
    /// *wrapping* nil — so if `decodeIfPresent` ever handed null to it, `chamber` would come back
    /// NON-nil and an open-frame printer would render `C 0°`. Bambuddy may omit the key or send it
    /// as null depending on how the model declares it, and both readings must land on "no chamber".
    func testAbsentAndNullChamberBothMeanNoChamber() throws {
        let dec = JSONDecoder()
        let absent = try dec.decode(Temperatures.self, from: Data(#"{"nozzle":220}"#.utf8))
        XCTAssertNil(absent.chamber, "key absent")

        let null = try dec.decode(Temperatures.self, from: Data(#"{"nozzle":220,"chamber":null}"#.utf8))
        XCTAssertNil(null.chamber, "key present, value null")

        let real = try dec.decode(Temperatures.self, from: Data(#"{"chamber":0}"#.utf8))
        XCTAssertEqual(real.chamber?.double, 0, "a real 0° must survive as a reading")
    }

    /// A chamber APPEARING is a change even when the reading rounds to the number a missing key
    /// would have compared as. `(nil ?? 0)` vs a real `0` is the trap this pins.
    func testAChamberAppearingIsWorthAPush() {
        var a = PrintActivityAttributes.ContentState()
        a.chamber = nil
        var b = a
        b.chamber = 0
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: b))
    }
}
#endif

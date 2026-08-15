import XCTest
@testable import Sprout

/// The six rules from the design handoff, each pinned.
///
/// These are not layout tests. They are tests that the screen never claims to know something about a
/// version that MakerWorld did not publish — which, on a popular model, is most of them.
final class VersionGroupingTests: XCTestCase {

    // MARK: Fixtures

    private func detail(seconds: Double? = 3600, grams: Double? = 20,
                        materials: [String] = ["PLA"]) -> MWProfileDetail {
        var d = MWProfileDetail()
        d.seconds = seconds
        d.grams = grams
        d.slots = materials.map { m in
            var s = MWSlot(); s.type = m; return s
        }
        return d
    }

    private func row(_ id: Int, title: String = "v", detail: MWProfileDetail? = nil,
                     summary: String? = nil, pictures: [String] = []) -> MWProfileRow {
        MWProfileRow(id: id, profileId: id * 10, title: title, coverUrl: nil,
                     detail: detail, summary: summary, pictures: pictures)
    }

    // MARK: Rule 1 — unlabelled rows are never reordered by a sort they have no data for

    func testUnlabelledVersionsStayInMakerWorldsOrderAtTheEndWhateverTheSort() {
        let rows = [row(1, detail: detail(seconds: 9000)),
                    row(2),                                   // no settings
                    row(3, detail: detail(seconds: 60)),
                    row(4)]                                   // no settings
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])

        for sort in VersionGrouping.Sort.allCases {
            let out = VersionGrouping.sorted(placed, by: sort)
            XCTAssertEqual(out.suffix(2).map(\.id), [2, 4],
                           "\(sort): the unlabelled rows must trail, in their original order")
            XCTAssertTrue(out.suffix(2).allSatisfy(\.isUnlabelled))
        }
    }

    /// The failure mode this prevents: a missing time defaulting to 0 and ranking "fastest".
    func testAVersionWithNoTimeNeverOutranksOneThatPublishesIt() {
        let rows = [row(1), row(2, detail: detail(seconds: 7200))]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])
        let out = VersionGrouping.sorted(placed, by: .fastest)
        XCTAssertEqual(out.map(\.id), [2, 1])
        XCTAssertFalse(out[0].marks.contains("FASTEST"),
                       "one measurable row is not a superlative — 'fastest of one' says nothing")
    }

    // MARK: Rule 2 — say the gap out loud

    func testTheCountLineStatesBothTheMatchesAndTheUnmeasurables() {
        XCTAssertEqual(VersionGrouping.countLine(matching: 7, total: 88, unlabelled: 51),
                       "7 of 88 match  ·  51 publish no settings")
    }

    /// With nothing filtered and nothing missing, the line must not manufacture a comparison.
    func testTheCountLineIsPlainWhenEverythingMatchesAndEverythingIsLabelled() {
        XCTAssertEqual(VersionGrouping.countLine(matching: 4, total: 4, unlabelled: 0), "4 versions")
        XCTAssertEqual(VersionGrouping.countLine(matching: 1, total: 1, unlabelled: 0), "1 version")
    }

    // MARK: Rule 3 — the material filter states what it does with unlabelled rows

    func testUnlabelledRowsAreDroppedByAnyFilterUnlessExplicitlyIncluded() {
        let rows = [row(1, detail: detail(materials: ["PLA"])), row(2)]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])

        var f = VersionGrouping.Filter()
        XCTAssertEqual(VersionGrouping.apply(f, to: placed).map(\.id), [1, 2],
                       "no filter at all keeps everything")

        f.materials = ["PLA"]
        XCTAssertEqual(VersionGrouping.apply(f, to: placed).map(\.id), [1],
                       "a row with no material cannot satisfy a material filter")

        f = VersionGrouping.Filter()
        f.includeUnlabelled = false
        XCTAssertEqual(VersionGrouping.apply(f, to: placed).map(\.id), [1])
    }

    // MARK: Rule 4 — Universal always passes

    func testUniversalPassesEveryMaterialFilter() {
        let rows = [row(1, detail: detail(materials: ["Universal"])),
                    row(2, detail: detail(materials: ["ABS"]))]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])
        var f = VersionGrouping.Filter()
        f.materials = ["PETG"]
        XCTAssertEqual(VersionGrouping.apply(f, to: placed).map(\.id), [1],
                       "Universal is the absence of a constraint, not a material to exclude")
    }

    func testUniversalIsNotOfferedAsAMaterialToFilterBy() {
        let rows = [row(1, detail: detail(materials: ["Universal"])),
                    row(2, detail: detail(materials: ["PLA", "PETG"]))]
        XCTAssertEqual(VersionGrouping.materialsPresent(rows), ["PETG", "PLA"])
    }

    // MARK: Rule 5/6 — unprintable is shown with the remedy, and only when actually known

    /// One tray per material named, in order. `place` takes TRAYS now, not a set of materials —
    /// because a set cannot answer "does each slot get its own spool".
    private func trays(_ materials: String...) -> [VersionGrouping.Tray] {
        materials.enumerated().map { i, m in
            VersionGrouping.Tray(unit: 0, slot: i, type: m.uppercased())
        }
    }

    func testAVersionNeedingAMaterialYouLackIsGroupedWithItsRemedy() {
        let rows = [row(1, detail: detail(materials: ["ABS"]))]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: trays("PLA"))
        XCTAssertEqual(placed[0].group, .needsFilament)
        XCTAssertEqual(placed[0].remedy, "load ABS to print")
    }

    /// "We don't know what's loaded" and "you don't have it" are different facts. Only the second
    /// justifies greying a row out — an empty AMS reading must not condemn every version.
    func testNothingIsCalledUnprintableWhenTheAmsReadingIsUnknown() {
        let rows = [row(1, detail: detail(materials: ["ABS"]))]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])
        XCTAssertEqual(placed[0].group, .oneColour)
        XCTAssertNil(placed[0].remedy)
    }

    func testUniversalNeverCountsAsAMaterialYouAreMissing() {
        let rows = [row(1, detail: detail(materials: ["Universal"]))]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: trays("PLA"))
        XCTAssertEqual(placed[0].group, .oneColour)
    }

    // MARK: Grouping

    /// TWO PLA trays, for a row that needs two PLA slots.
    ///
    /// This supplied one, and asserted the two-slot row was `.multiColour` — which is what the old
    /// set-subtraction `place` returned, because it asked "is PLA loaded" rather than "does each
    /// slot get a spool". The test was pinning the bug. This case is about GROUPING, so it now
    /// supplies enough filament for grouping to be the only thing under test.
    func testGroupsSplitOnColourCountAndMakerWorldsOwnPick() {
        let rows = [row(1, detail: detail()),
                    row(2, detail: detail(materials: ["PLA", "PLA"])),
                    row(3, detail: detail()),
                    row(4)]
        let placed = VersionGrouping.place(rows, defaultInstanceId: 3, trays: trays("PLA", "PLA"))
        XCTAssertEqual(placed.first { $0.id == 3 }?.group, .recommended)
        XCTAssertEqual(placed.first { $0.id == 1 }?.group, .oneColour)
        XCTAssertEqual(placed.first { $0.id == 2 }?.group, .multiColour)
        XCTAssertEqual(placed.first { $0.id == 4 }?.group, .unlabelled)
    }

    /// MakerWorld's own pre-selection is frequently one of the undescribed rows. It must land in the
    /// trailing group like any other, not be promoted to RECOMMENDED on the strength of a flag.
    func testMakerWorldsPickIsNotPromotedWhenItPublishesNoSettings() {
        let placed = VersionGrouping.place([row(1)], defaultInstanceId: 1, trays: [])
        XCTAssertEqual(placed[0].group, .unlabelled)
    }

    // MARK: Superlatives

    func testSuperlativesMarkTheExtremesSoTheySurviveGrouping() {
        let rows = [row(1, detail: detail(seconds: 100, grams: 90)),
                    row(2, detail: detail(seconds: 900, grams: 10)),
                    row(3, detail: detail(seconds: 500, grams: 50))]
        let out = VersionGrouping.sorted(
            VersionGrouping.place(rows, defaultInstanceId: nil, trays: []), by: .recommended)
        XCTAssertTrue(out.first { $0.id == 1 }!.marks.contains("FASTEST"))
        XCTAssertTrue(out.first { $0.id == 2 }!.marks.contains("LIGHTEST"))
        XCTAssertTrue(out.first { $0.id == 3 }!.marks.isEmpty)
    }

    // MARK: Filters that need real data

    func testOnlyWithPhotosOrNotesKeepsExactlyThoseThatHaveEither() {
        let rows = [row(1, detail: detail(), summary: "0.2mm"),
                    row(2, detail: detail(), pictures: ["a.png"]),
                    row(3, detail: detail())]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])
        var f = VersionGrouping.Filter()
        f.onlyWithPhotosOrNotes = true
        XCTAssertEqual(VersionGrouping.apply(f, to: placed).map(\.id), [1, 2])
    }

    func testTimeAndWeightCapsFilterOnPublishedValues() {
        let rows = [row(1, detail: detail(seconds: 600, grams: 10)),
                    row(2, detail: detail(seconds: 7200, grams: 200))]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])
        var f = VersionGrouping.Filter()
        f.maxSeconds = 1800
        XCTAssertEqual(VersionGrouping.apply(f, to: placed).map(\.id), [1])
        f = VersionGrouping.Filter()
        f.maxGrams = 50
        XCTAssertEqual(VersionGrouping.apply(f, to: placed).map(\.id), [1])
    }

    func testActiveCountDrivesTheToolbarBadge() {
        var f = VersionGrouping.Filter()
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(f.activeCount, 0)
        f.materials = ["PLA"]
        f.onlyPrintableNow = true
        XCTAssertTrue(f.isActive)
        XCTAssertEqual(f.activeCount, 2)
    }
    // MARK: Which spool serves which slot

    private func tray(_ unit: Int, _ slot: Int, _ type: String) -> VersionGrouping.Tray {
        VersionGrouping.Tray(unit: unit, slot: slot, type: type)
    }

    private func slot(_ type: String?) -> MWSlot {
        var s = MWSlot(); s.type = type; return s
    }

    /// The bug this exists to prevent: reporting the same tray for every slot of a material, so a
    /// three-colour version claimed to print from one spool. "The material is loaded" and "this
    /// slot has a tray" are different questions.
    func testEachSlotGetsItsOwnTray() {
        let trays = [tray(0, 0, "PLA"), tray(0, 1, "PLA"), tray(0, 2, "PETG")]
        let got = VersionGrouping.assignTrays(slots: [slot("PLA"), slot("PLA"), slot("PETG")], trays: trays)
        XCTAssertEqual(got.map { $0?.slot }, [0, 1, 2])
        XCTAssertEqual(Set(got.compactMap { $0?.slot }).count, 3, "no tray may serve two slots")
    }

    func testASlotWithNoTrayLeftGetsNothingRatherThanSomeoneElsesTray() {
        let trays = [tray(0, 0, "PLA")]
        let got = VersionGrouping.assignTrays(slots: [slot("PLA"), slot("PLA")], trays: trays)
        XCTAssertEqual(got[0]?.slot, 0)
        XCTAssertNil(got[1], "the second PLA slot has no tray of its own and must say so")
    }

    /// Universal asks for nothing in particular, so nothing is claimed on its behalf.
    func testUniversalSlotsClaimNoTray() {
        let got = VersionGrouping.assignTrays(slots: [slot("Universal"), slot(nil)],
                                              trays: [tray(0, 0, "PLA")])
        XCTAssertEqual(got.compactMap { $0 }.count, 0)
    }

    /// "You have none" and "you have fewer than this needs" are different problems with different
    /// fixes, so they are counted separately.
    func testShortfallDistinguishesNoneFromNotEnough() {
        let trays = [tray(0, 0, "PLA")]
        let short = VersionGrouping.shortfall(slots: [slot("PLA"), slot("PLA"), slot("ABS")], trays: trays)
        XCTAssertEqual(short["PLA"], 1, "two wanted, one loaded")
        XCTAssertEqual(short["ABS"], 1, "one wanted, none loaded")
        XCTAssertNil(VersionGrouping.shortfall(slots: [slot("PLA")], trays: trays)["PLA"])
    }

    func testShortfallIgnoresUniversal() {
        XCTAssertTrue(VersionGrouping.shortfall(slots: [slot("Universal")], trays: []).isEmpty)
    }

}

/// The tray-COUNT rule, which `place` used to be blind to.
///
/// It computed `missing` by set subtraction — "is this material loaded?" — so a version needing
/// three PLA slots was reported as printable by a machine holding one PLA spool, under the words
/// "N fit your filament". `assignTrays` already answered this correctly and its own doc comment
/// describes the bug; `place` was the copy that never got the fix.
final class VersionGroupingTrayCountTests: XCTestCase {

    private func trays(_ materials: String...) -> [VersionGrouping.Tray] {
        materials.enumerated().map { i, m in
            VersionGrouping.Tray(unit: 0, slot: i, type: m.uppercased())
        }
    }

    private func row(_ id: Int, materials: [String]) -> MWProfileRow {
        MWProfileRow(
            id: id,
            title: "v\(id)",
            detail: MWProfileDetail(slots: materials.map { MWSlot(type: $0) })
        )
    }

    func testAVersionNeedingMoreSpoolsThanYouHaveDoesNotFit() {
        let rows = [row(1, materials: ["PLA", "PLA", "PLA"])]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: trays("PLA"))
        XCTAssertEqual(placed[0].group, .needsFilament, "one spool cannot serve three PLA slots")
        XCTAssertNotNil(placed[0].remedy)
    }

    func testEnoughSpoolsForEverySlotDoesFit() {
        let rows = [row(1, materials: ["PLA", "PLA", "PLA"])]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: trays("PLA", "PLA", "PLA"))
        XCTAssertEqual(placed[0].group, .multiColour)
        XCTAssertNil(placed[0].remedy)
    }

    /// A partial shortfall names only what is actually short.
    func testTheRemedyNamesOnlyTheSlotsThatWentUnserved() {
        let rows = [row(1, materials: ["PLA", "PETG", "PETG"])]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: trays("PLA", "PETG"))
        XCTAssertEqual(placed[0].group, .needsFilament)
        XCTAssertEqual(placed[0].remedy, "load PETG to print", "one PETG slot is served, the second is not")
    }

    /// Unchanged by the fix: no trays means "we don't know", never "you have nothing".
    func testAnUnknownAmsStillCondemnsNothing() {
        let rows = [row(1, materials: ["PLA", "PLA", "PLA"])]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: [])
        XCTAssertNotEqual(placed[0].group, .needsFilament)
    }

    /// Universal claims no tray, so it can never be the reason a version does not fit.
    func testUniversalClaimsNoTray() {
        let rows = [row(1, materials: ["Universal", "PLA"])]
        let placed = VersionGrouping.place(rows, defaultInstanceId: nil, trays: trays("PLA"))
        XCTAssertNotEqual(placed[0].group, .needsFilament)
    }
}

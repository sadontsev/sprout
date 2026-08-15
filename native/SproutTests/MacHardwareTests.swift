// The Mac Hardware section's pure decisions: what a humidity reading says, why a damp unit has no
// drying control, what to advise about it, and what a status read nine seconds after a Start
// actually establishes.
//
// Every case here is a question that used to be answered by a NEARBY one — "can this unit dry"
// standing in for "is this unit damp", "this unit has no heater" standing in for "the printer hasn't
// said", "the printer refused it" standing in for "the AMS still reports no cycle".
//
// **These cases only run on the macOS test destination.** `MacDryingCopy` lives inside
// `#if os(macOS)` because it is Mac view support, so the iOS command in CLAUDE.md contributes zero
// cases from this file — a green iOS run is not evidence that any of this passed. Run
// `xcodebuild … -destination 'platform=macOS' test` as well (18-mac-port-architecture.md, Build).
#if os(macOS)
import XCTest
@testable import Sprout

// MARK: - Fixtures

private func makeUnit(
    id: Int = 0,
    label: String = "AMS 1",
    kind: AmsKind = .ams,
    humidity: Double? = nil,
    capacity: Int = 4,
    loaded: Int = 2
) -> AmsUnitVM {
    AmsUnitVM(
        id: id,
        label: label,
        kind: kind,
        capacity: capacity,
        loaded: loaded,
        maxDryTemp: kind == .ht ? 85 : 65,
        humidity: humidity,
        tempC: nil,
        extruder: nil,
        serialTail: "",
        dryingMinLeft: 0
    )
}

private func makeDryer(
    amsId: Int = 0,
    isHt: Bool = false,
    active: Bool = false,
    remainingMin: Int = 0,
    remainingText: String = "—",
    humidityPct: Int? = nil
) -> DryerVM {
    DryerVM(
        amsId: amsId,
        isHt: isHt,
        maxTemp: isHt ? 85 : 65,
        active: active,
        remainingMin: remainingMin,
        remainingText: remainingText,
        humidityPct: humidityPct,
        tempC: nil,
        targetTemp: nil,
        filament: "",
        stage: nil,
        blockers: [],
        options: []
    )
}

// MARK: - Severity

final class MacHardwareSeverityTests: XCTestCase {

    /// The dot colour follows `HardwareTriage.Item.weight`, which is already the app's severity
    /// order — it must not be re-derived from `isDue`/humidity, or the dot would eventually
    /// contradict the order the list beneath it is sorted in.
    func testOverdueServiceIsUrgentAndDampIsNot() {
        let overdue = HardwareTriage.Item(segment: .service, text: "Nozzle overdue", weight: 100)
        let damp = HardwareTriage.Item(segment: .filament, text: "AMS 1 at 38 % RH", weight: 50)
        XCTAssertEqual(MacHardwareSeverity.of(overdue), .now)
        XCTAssertEqual(MacHardwareSeverity.of(damp), .soon)
        XCTAssertEqual(MacHardwareSeverity.worst([damp, overdue]), .now)
        XCTAssertEqual(MacHardwareSeverity.worst([damp]), .soon)
        XCTAssertNil(MacHardwareSeverity.worst([]))
    }

    /// A clean segment gets no dot even when another segment is on fire.
    func testWorstIsPerSegment() {
        let items = [
            HardwareTriage.Item(segment: .service, text: "Nozzle overdue", weight: 100),
            HardwareTriage.Item(segment: .filament, text: "AMS 1 at 38 % RH", weight: 50),
        ]
        XCTAssertEqual(MacHardwareSeverity.worst(items, in: .service), .now)
        XCTAssertEqual(MacHardwareSeverity.worst(items, in: .filament), .soon)
        XCTAssertNil(MacHardwareSeverity.worst(items, in: .nozzles))
    }
}

// MARK: - Dampness

final class MacDampnessTests: XCTestCase {

    /// Three answers, not a Bool: "did this unit report a reading" is a different question from
    /// "is this unit above the threshold", and `!isDamp` was answering the second for units that had
    /// never answered the first.
    func testUnreportedHumidityIsNeitherDampNorDry() {
        XCTAssertEqual(MacDryingCopy.dampness(humidityPct: nil), .unknown)
        // An AMS that has taken no reading publishes 0 — which is not "bone dry".
        XCTAssertEqual(MacDryingCopy.dampness(humidityPct: 0), .unknown)
    }

    func testDampnessUsesTheThresholdTheCopyQuotes() {
        let threshold = Int(HardwareTriage.dampRH)
        XCTAssertEqual(MacDryingCopy.dampness(humidityPct: threshold), .damp)
        XCTAssertEqual(MacDryingCopy.dampness(humidityPct: threshold - 1), .dry)
        XCTAssertEqual(MacDryingCopy.dampness(humidityPct: 38), .damp)
    }
}

// MARK: - Damp with no dryer

final class MacDampWithoutDryerTests: XCTestCase {

    /// The prototype's own mock: an AMS Lite at 38 % RH. Triage flags it from `amsUnits`; the drying
    /// cards come from `Dryer.present`, which knows nothing about it. Without this list the picker
    /// paints an amber dot pointing at a pane that says nothing whatsoever about the reading.
    func testDampUnitWithNoDryerIsReturned() {
        let lite = makeUnit(id: 0, label: "AMS 1", humidity: 38)
        XCTAssertEqual(MacDryingCopy.dampWithoutDryer([lite], dryers: []).map(\.id), [0])
    }

    /// A unit that CAN dry is not stranded — it gets the card with the Start button instead, and two
    /// cards about the same unit would be the section arguing with itself.
    func testDampUnitWithADryerIsNotStranded() {
        let pro = makeUnit(id: 0, humidity: 38)
        let dryer = makeDryer(amsId: 0, humidityPct: 38)
        XCTAssertTrue(MacDryingCopy.dampWithoutDryer([pro], dryers: [dryer]).isEmpty)
    }

    /// No reading is not a damp reading. 0 is the value an AMS publishes before it has measured.
    func testMissingZeroAndNonFiniteReadingsAreNotDamp() {
        let none = makeUnit(id: 0, humidity: nil)
        let zero = makeUnit(id: 1, humidity: 0)
        let nan = makeUnit(id: 2, humidity: .nan)
        let dry = makeUnit(id: 3, humidity: 12)
        XCTAssertTrue(MacDryingCopy.dampWithoutDryer([none, zero, nan, dry], dryers: []).isEmpty)
    }

    /// Only the stranded ones, on a machine that has both kinds fitted.
    func testMixedMachineReturnsOnlyTheUnitsWithNoDryer() {
        let pro = makeUnit(id: 0, label: "AMS 1", humidity: 40)
        let lite = makeUnit(id: 1, label: "AMS 2", humidity: 41)
        let stranded = MacDryingCopy.dampWithoutDryer([pro, lite], dryers: [makeDryer(amsId: 0)])
        XCTAssertEqual(stranded.map(\.label), ["AMS 2"])
    }
}

// MARK: - Why there is no dryer

final class MacNoDryerCauseTests: XCTestCase {

    /// `supportsDrying` is `Bool?` and `nil` is NOT `false`: a printer that never reports the field
    /// strands every unit it has, heated ones included. Reading the absence as "this unit has no
    /// heater" is the claim that told an AMS HT to move its spool into an AMS HT.
    func testUnreportedSupportIsAPrinterLevelSilence() {
        XCTAssertEqual(MacDryingCopy.noDryerCause(supportsDrying: nil), .printerReportsNoDrying)
        XCTAssertEqual(MacDryingCopy.noDryerCause(supportsDrying: false), .printerReportsNoDrying)
        XCTAssertEqual(MacDryingCopy.noDryerCause(supportsDrying: true), .unitHasNoHeater)
    }
}

final class MacNoDryerReasonTests: XCTestCase {

    private let ht = MacDryingCopy.DampUnit(label: "AMS HT", rh: 41, isHt: true)
    private let lite = MacDryingCopy.DampUnit(label: "AMS 1", rh: 38, isHt: false)

    /// The reading and the threshold are the only numbers in the sentence, and they are the ones the
    /// dot and the drying copy quote.
    func testNamesTheReadingAndTheThreshold() {
        let text = MacDryingCopy.noDryerReason([lite], cause: .unitHasNoHeater, dryElsewhere: [])
        XCTAssertTrue(text.contains("AMS 1 at 38 % RH"), text)
        XCTAssertTrue(text.contains("\(Int(HardwareTriage.dampRH)) %"), text)
    }

    /// **The N4 case.** An AMS HT is a heater; it must never be told to move its spool to a unit that
    /// can heat, and it must never be described as having no dryer.
    func testHtIsNeverToldToMoveItsSpoolToAHeatedUnit() {
        for cause in [MacDryingCopy.NoDryerCause.printerReportsNoDrying, .unitHasNoHeater] {
            let text = MacDryingCopy.noDryerReason([ht], cause: cause, dryElsewhere: [])
            XCTAssertFalse(text.contains("move it"), "\(cause): \(text)")
            XCTAssertFalse(text.contains("This unit has no dryer"), "\(cause): \(text)")
            XCTAssertTrue(text.contains("AMS HT has one built in")
                          || text.contains("AMS HT has a heater built in"), "\(cause): \(text)")
        }
    }

    /// A printer that reports no drying support strands every unit, so there is nowhere on the
    /// machine to move the spool TO — the advice is a standalone dryer or the printer's own screen.
    func testPrinterSilenceDoesNotOfferAMove() {
        let text = MacDryingCopy.noDryerReason([lite], cause: .printerReportsNoDrying,
                                               dryElsewhere: [])
        XCTAssertTrue(text.contains("isn’t reporting drying support"), text)
        XCTAssertFalse(text.contains("move it"), text)
        XCTAssertTrue(text.contains("standalone filament dryer"), text)
    }

    /// When the printer CAN dry and another unit is heated, name that unit. "A unit that can heat
    /// (AMS 2 Pro or HT)" described hardware the owner may not own.
    func testNamesTheUnitsThatCanActuallyHeat() {
        let one = MacDryingCopy.noDryerReason([lite], cause: .unitHasNoHeater,
                                              dryElsewhere: ["AMS 2"])
        XCTAssertTrue(one.contains("move it to AMS 2, which can heat"), one)

        let two = MacDryingCopy.noDryerReason([lite], cause: .unitHasNoHeater,
                                              dryElsewhere: ["AMS 2", "AMS HT"])
        XCTAssertTrue(two.contains("move it to AMS 2 or AMS HT"), two)

        let three = MacDryingCopy.noDryerReason([lite], cause: .unitHasNoHeater,
                                                dryElsewhere: ["AMS 2", "AMS 3", "AMS HT"])
        XCTAssertTrue(three.contains("AMS 2, AMS 3 or AMS HT"), three)
    }

    /// Nowhere to move it: say so, rather than offering a move the machine cannot make.
    func testNoHeatedUnitAnywhereOffersOnlyAStandaloneDryer() {
        let text = MacDryingCopy.noDryerReason([lite], cause: .unitHasNoHeater, dryElsewhere: [])
        XCTAssertFalse(text.contains("move it"), text)
        XCTAssertTrue(text.contains("no other unit on this printer can heat"), text)
    }

    /// Several units in one card: every reading is named, and the subject agrees in number.
    func testSeveralStrandedUnitsAreAllNamed() {
        let second = MacDryingCopy.DampUnit(label: "AMS 2", rh: 44, isHt: false)
        let text = MacDryingCopy.noDryerReason([lite, second], cause: .unitHasNoHeater,
                                               dryElsewhere: [])
        XCTAssertTrue(text.contains("AMS 1 at 38 % RH, AMS 2 at 44 % RH"), text)
        XCTAssertTrue(text.contains("These units have no dryer"), text)
    }

    /// Mixed kinds cannot take either single-kind sentence: an HT does have a heater, the AMS Lite
    /// beside it does not, and the one thing true of both is that the printer reports no dryer.
    func testMixedKindsDoNotClaimEitherHardwareFact() {
        let text = MacDryingCopy.noDryerReason([lite, ht], cause: .unitHasNoHeater, dryElsewhere: [])
        XCTAssertTrue(text.contains("isn’t reporting a dryer for these units"), text)
        XCTAssertFalse(text.contains("These units have no dryer"), text)
    }

    /// Nothing stranded ⇒ nothing said. The card is not drawn in that case, and an empty list must
    /// not produce a sentence about "0 units".
    func testEmptyListSaysNothing() {
        XCTAssertEqual(MacDryingCopy.noDryerReason([], cause: .unitHasNoHeater, dryElsewhere: []), "")
    }
}

// MARK: - The inspector's Dryer reading

final class MacDryerLineTests: XCTestCase {

    func testRunningAndIdleUnitsReadFromTheDryer() {
        XCTAssertEqual(
            MacDryingCopy.dryerLine(makeDryer(active: true, remainingMin: 344, remainingText: "5h 44m"),
                                    cause: .unitHasNoHeater),
            "Drying · 5h 44m"
        )
        XCTAssertEqual(MacDryingCopy.dryerLine(makeDryer(), cause: .unitHasNoHeater), "Idle")
    }

    /// The mirror image of the AMS Lite bug: `Dryer.present` is empty for EVERY unit when the printer
    /// does not report `supportsDrying`, so "Not supported" would be a claim about hardware — said
    /// about an AMS HT, which is nothing but a dryer.
    func testMissingDryerDistinguishesNoHeaterFromNoReport() {
        XCTAssertEqual(MacDryingCopy.dryerLine(nil, cause: .unitHasNoHeater), "Not supported")
        XCTAssertEqual(MacDryingCopy.dryerLine(nil, cause: .printerReportsNoDrying), "Not reported")
    }

    func testTheTooltipExplainsWhichAbsenceItIs() {
        XCTAssertTrue(MacDryingCopy.dryerNote(nil, cause: .unitHasNoHeater).contains("no heater"))
        XCTAssertTrue(MacDryingCopy.dryerNote(nil, cause: .printerReportsNoDrying)
            .contains("isn’t reporting drying support"))
        XCTAssertTrue(MacDryingCopy.dryerNote(makeDryer(active: true), cause: .unitHasNoHeater)
            .contains("running"))
    }
}

// MARK: - The verification verdict

final class MacDryingNotStartedTests: XCTestCase {

    /// It states what was OBSERVED. A status read nine seconds later cannot establish "the printer
    /// rejected the command" — a slow AMS reports exactly the same way.
    func testQuotesTheDelayItActuallyWaited() {
        for mode in LanMode.allCases {
            let text = MacDryingCopy.notStarted(afterSeconds: 9, lanMode: mode)
            XCTAssertTrue(text.contains("9 seconds after the command"), "\(mode): \(text)")
            XCTAssertTrue(text.contains("still reports no cycle"), "\(mode): \(text)")
        }
    }

    /// With Developer Mode SEEN on, telling the user to go and switch it on is advice the app already
    /// knows is wrong.
    func testDeveloperModeAdviceIsWithheldWhenTheAppHasSeenItOn() {
        let on = MacDryingCopy.notStarted(afterSeconds: 9, lanMode: .on)
        XCTAssertFalse(on.contains("Developer Mode"), on)
        XCTAssertTrue(on.contains("check its screen"), on)

        for mode in [LanMode.off, .unknown] {
            let text = MacDryingCopy.notStarted(afterSeconds: 9, lanMode: mode)
            XCTAssertTrue(text.contains("Developer Mode"), "\(mode): \(text)")
        }
    }

    /// It goes to `model.toast`, which has no title of its own, so the message has to name its own
    /// subject in the first words.
    func testTheMessageIsSelfIdentifying() {
        XCTAssertTrue(MacDryingCopy.notStarted(afterSeconds: 9, lanMode: .unknown)
            .hasPrefix("Drying hasn’t started"))
    }
}
#endif

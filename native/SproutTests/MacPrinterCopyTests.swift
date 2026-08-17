#if os(macOS)
import XCTest
@testable import Sprout

/// The Printer card's AMS heading and summary.
///
/// Both were reported as confusing by the owner, whose machine is **two AMS 2 Pro plus one AMS HT** —
/// three units, nine slots. The card said "AMS 2 PRO · 8 of 9 slots loaded · 17 % RH", which gets three
/// separate things wrong at once, and the slot rows below it were right all along ("AMS HT · 1"). Only
/// the heading and the summary lied.
final class MacPrinterAmsCopyTests: XCTestCase {

    private func unit(_ label: String, kind: AmsKind, capacity: Int, humidity: Double?) -> AmsUnitVM {
        AmsUnitVM(id: kind == .ht ? 128 : 0, label: label, kind: kind,
                  capacity: capacity, loaded: capacity, maxDryTemp: kind == .ht ? 85 : 65,
                  humidity: humidity, tempC: nil, extruder: nil,
                  serialTail: label, dryingMinLeft: 0)
    }

    private func slot(empty: Bool) -> AmsSlotVM {
        AmsSlotVM(label: empty ? "Empty" : "PLA", color: nil, pct: "58%", active: false, empty: empty,
                  unitId: 0, unitLabel: "AMS 1", localId: 0, globalId: 0, extruder: nil)
    }

    /// The owner's real machine.
    private var threeUnits: [AmsUnitVM] {
        [unit("AMS 1", kind: .ams, capacity: 4, humidity: 17),
         unit("AMS 2", kind: .ams, capacity: 4, humidity: 12),
         unit("AMS HT", kind: .ht, capacity: 1, humidity: 8)]
    }

    // MARK: The heading

    /// A MODEL name must not head a block it does not describe. "AMS 2 PRO" sat over nine slots, one of
    /// which is an HT tray — claiming a unit type for a row that does not have it.
    func testAModelNameIsNotUsedWhenSeveralUnitsAreFitted() {
        XCTAssertEqual(MacPrinterCopy.amsHeading(units: threeUnits, profileLabel: "AMS 2 Pro"), "AMS")
    }

    /// With exactly one unit the model name IS precise, so it is kept — this is not a blanket removal.
    func testTheModelNameSurvivesWhenItNamesTheOnlyUnit() {
        let one = [unit("AMS 1", kind: .ams, capacity: 4, humidity: 17)]
        XCTAssertEqual(MacPrinterCopy.amsHeading(units: one, profileLabel: "AMS 2 Pro"), "AMS 2 Pro")
    }

    /// Two units of the SAME model still lose the name: "AMS 2 Pro" over eight slots reads as one unit
    /// with eight trays, which is not a thing that exists.
    func testTwoUnitsOfOneModelAlsoLoseTheName() {
        let two = [unit("AMS 1", kind: .ams, capacity: 4, humidity: 17),
                   unit("AMS 2", kind: .ams, capacity: 4, humidity: 12)]
        XCTAssertEqual(MacPrinterCopy.amsHeading(units: two, profileLabel: "AMS 2 Pro"), "AMS")
    }

    // MARK: The summary

    /// Nine slots under one heading looked like one improbably large unit. Say how many there are.
    func testTheUnitCountLeadsWhenThereIsMoreThanOne() {
        let slots = Array(repeating: slot(empty: false), count: 8) + [slot(empty: true)]
        let summary = MacPrinterCopy.amsSummary(slots: slots, units: threeUnits)
        XCTAssertTrue(summary.hasPrefix("3 units · "), "got: \(summary)")
        XCTAssertTrue(summary.contains("8 of 9 slots loaded"), "got: \(summary)")
    }

    /// One unit needs no count — "1 units" would be worse than nothing.
    func testASingleUnitIsNotCounted() {
        let one = [unit("AMS 1", kind: .ams, capacity: 4, humidity: 17)]
        let summary = MacPrinterCopy.amsSummary(slots: [slot(empty: false)], units: one)
        XCTAssertFalse(summary.contains("unit"), "got: \(summary)")
    }

    /// The humidity is the MAXIMUM across units, chosen so the single line is the reading triage would
    /// flag. Printed bare it read as *the* humidity of *the* AMS.
    func testTheWorstHumidityIsLabelledAsAMaximum() {
        let summary = MacPrinterCopy.amsSummary(slots: [slot(empty: false)], units: threeUnits)
        XCTAssertTrue(summary.contains("up to 17 % RH"), "got: \(summary)")
    }

    /// …but with a single reading there is nothing to be "up to".
    func testASingleReadingIsNotCalledAMaximum() {
        let one = [unit("AMS 1", kind: .ams, capacity: 4, humidity: 17)]
        let summary = MacPrinterCopy.amsSummary(slots: [slot(empty: false)], units: one)
        XCTAssertTrue(summary.contains("17 % RH"), "got: \(summary)")
        XCTAssertFalse(summary.contains("up to"), "got: \(summary)")
    }

    /// A unit reporting no humidity must not turn one reading into a range.
    func testAUnitWithNoHumidityDoesNotCreateARange() {
        let mixed = [unit("AMS 1", kind: .ams, capacity: 4, humidity: 17),
                     unit("AMS 2", kind: .ams, capacity: 4, humidity: nil)]
        let summary = MacPrinterCopy.amsSummary(slots: [slot(empty: false)], units: mixed)
        XCTAssertTrue(summary.contains("17 % RH"), "got: \(summary)")
        XCTAssertFalse(summary.contains("up to"), "one reading is not a range — got: \(summary)")
    }

    /// No slots at all is a fact about the printer, not a zero.
    func testNoSlotsSaysNotReporting() {
        XCTAssertEqual(MacPrinterCopy.amsSummary(slots: [], units: threeUnits), "not reporting")
    }

    /// Every unit silent: the counts still stand, and no humidity is invented.
    func testAllUnitsSilentStillCountsSlots() {
        let silent = [unit("AMS 1", kind: .ams, capacity: 4, humidity: nil),
                      unit("AMS HT", kind: .ht, capacity: 1, humidity: nil)]
        let summary = MacPrinterCopy.amsSummary(slots: [slot(empty: false)], units: silent)
        XCTAssertFalse(summary.contains("RH"), "got: \(summary)")
        XCTAssertTrue(summary.contains("2 units"), "got: \(summary)")
    }
}
#endif

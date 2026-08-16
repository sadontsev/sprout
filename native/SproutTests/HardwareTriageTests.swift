import XCTest
@testable import Sprout

/// What the Hardware tab says needs attention, and — more importantly — what it stays quiet about.
final class HardwareTriageTests: XCTestCase {

    private func item(_ name: String, hoursUntilDue: Double?, enabled: Bool? = nil) -> MaintenanceItem {
        var m = MaintenanceItem(id: Int.random(in: 1...9999), maintenanceTypeName: name)
        m.hoursUntilDue = hoursUntilDue.map { LooseNumber($0) }
        m.enabled = enabled
        return m
    }

    // MARK: Silence

    /// No card at all when nothing is wrong. An "all good" banner would occupy the top of every
    /// screen forever and train the eye to skip exactly where the warnings appear.
    func testNothingWrongMeansNoCard() {
        let items = HardwareTriage.items(maintenance: [], humidities: [], nozzlesKnown: true)
        XCTAssertTrue(items.isEmpty)
        XCTAssertNil(HardwareTriage.headline(items))
        XCTAssertTrue(HardwareTriage.flagged(items).isEmpty)
    }

    /// An unknown humidity is not a dry spool and not a wet one. Reporting it either way invents a
    /// reading the printer never sent.
    func testAnUnknownHumidityIsNotReported() {
        let items = HardwareTriage.items(maintenance: [],
                                         humidities: [(label: "AMS 1", rh: nil)],
                                         nozzlesKnown: true)
        XCTAssertTrue(items.isEmpty)
    }

    /// A machine with no swappable rack has nothing to say about nozzles — that is not a fault, and
    /// flagging it would put a permanent warning on every A1.
    func testNoNozzleDataIsNotAFault() {
        let items = HardwareTriage.items(maintenance: [], humidities: [], nozzlesKnown: false)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: Service

    /// Counted from a NEGATIVE remaining figure rather than `isDue`: `isDue` goes true the moment
    /// the interval elapses, while "overdue" is the thing you can state as a number.
    func testOnlyNegativeRemainingCountsAsOverdue() {
        let items = HardwareTriage.items(
            maintenance: [item("Nozzle wipe", hoursUntilDue: -6), item("Belt check", hoursUntilDue: 20)],
            humidities: [], nozzlesKnown: true)
        XCTAssertEqual(items.map(\.text), ["Nozzle wipe overdue"])
        XCTAssertEqual(items.first?.segment, .service)
    }

    func testSeveralOverdueItemsCollapseToACount() {
        let items = HardwareTriage.items(
            maintenance: [item("A", hoursUntilDue: -1), item("B", hoursUntilDue: -2)],
            humidities: [], nozzlesKnown: true)
        XCTAssertEqual(items.map(\.text), ["2 service items overdue"])
    }

    /// A reminder the owner switched off is not overdue — it is off.
    func testADisabledReminderIsNotOverdue() {
        let items = HardwareTriage.items(
            maintenance: [item("Nozzle wipe", hoursUntilDue: -6, enabled: false)],
            humidities: [], nozzlesKnown: true)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: Humidity

    func testDampSpoolsAreFlaggedPerUnitWithTheirOwnReading() {
        let items = HardwareTriage.items(
            maintenance: [],
            humidities: [(label: "AMS 1", rh: 38), (label: "AMS HT", rh: 12)],
            nozzlesKnown: true)
        XCTAssertEqual(items.map(\.text), ["AMS 1 at 38 % RH"],
                       "a dry unit must not be dragged in by a damp sibling")
        XCTAssertEqual(HardwareTriage.flagged(items), [.filament])
    }

    func testTheThresholdIsInclusive() {
        let at = HardwareTriage.items(maintenance: [],
                                      humidities: [(label: "AMS 1", rh: HardwareTriage.dampRH)],
                                      nozzlesKnown: true)
        XCTAssertEqual(at.count, 1, "at the threshold is over it — the copy says 'above the 30 %'")
    }

    // MARK: Ordering and wording

    /// Service outranks humidity: a wet spool is worth saying, an overdue service item is the one
    /// that makes tomorrow's print wrong.
    func testServiceSortsAboveHumidity() {
        let items = HardwareTriage.items(
            maintenance: [item("Nozzle wipe", hoursUntilDue: -6)],
            humidities: [(label: "AMS 1", rh: 38)],
            nozzlesKnown: true)
        XCTAssertEqual(items.map(\.segment), [.service, .filament])
        XCTAssertEqual(HardwareTriage.headline(items), "2 things need you")
        XCTAssertEqual(HardwareTriage.detail(items), "Nozzle wipe overdue  ·  AMS 1 at 38 % RH")
        XCTAssertEqual(HardwareTriage.flagged(items), [.service, .filament])
    }

    func testOneThingIsSingular() {
        let items = HardwareTriage.items(maintenance: [item("A", hoursUntilDue: -1)],
                                         humidities: [], nozzlesKnown: true)
        XCTAssertEqual(HardwareTriage.headline(items), "1 thing needs you")
    }

    // MARK: The drying reason

    /// The sentence must agree with the threshold that triggered it, or the card argues with itself.
    func testTheDryingReasonQuotesTheThresholdThatTriggeredIt() {
        let reason = HardwareTriage.dryingReason(rh: 38, maxDryTemp: 65)
        XCTAssertTrue(reason.contains("38 %"))
        XCTAssertTrue(reason.contains("\(Int(HardwareTriage.dampRH)) %"))
        XCTAssertTrue(reason.contains("55 °C"))
    }

    /// An AMS that cannot reach 55 °C must not be told to run at 55 °C.
    func testTheDryingReasonNeverExceedsTheUnitsCeiling() {
        XCTAssertTrue(HardwareTriage.dryingReason(rh: 40, maxDryTemp: 45).contains("45 °C"))
    }
    /// Shipped once and caught on screen: "1 thing needs you" directly above "4 service items
    /// overdue". Several overdue items collapse into one readable LINE, but the headline counts
    /// PROBLEMS — otherwise the card contradicts itself in the space of two lines.
    func testTheHeadlineCountsProblemsNotCollapsedLines() {
        let items = HardwareTriage.items(
            maintenance: [item("A", hoursUntilDue: -1), item("B", hoursUntilDue: -2),
                          item("C", hoursUntilDue: -3), item("D", hoursUntilDue: -4)],
            humidities: [], nozzlesKnown: true)
        XCTAssertEqual(items.count, 1, "still one line")
        XCTAssertEqual(HardwareTriage.detail(items), "4 service items overdue")
        XCTAssertEqual(HardwareTriage.headline(items), "4 things need you", "…but four problems")
    }

    func testCollapsedAndUncollapsedProblemsAddUp() {
        let items = HardwareTriage.items(
            maintenance: [item("A", hoursUntilDue: -1), item("B", hoursUntilDue: -2)],
            humidities: [(label: "AMS 1", rh: 38)],
            nozzlesKnown: true)
        XCTAssertEqual(HardwareTriage.headline(items), "3 things need you")
    }

}

/// The Service list and the triage count must answer the SAME question.
///
/// They did not, and the gap was visible: an item Bambuddy returns with no `enabled` field counted
/// as overdue in `HardwareTriage` (`enabled != false`) and was dropped from the list
/// (`enabled ?? false`). The result was a red dot, a "1 thing needs you" row in the inspector, and a
/// Service pane with nothing in it — the codebase's signature bug, two predicates one word apart.
final class ServiceListAgreesWithTriageTests: XCTestCase {

    private func item(_ name: String, hoursUntilDue: Double?, enabled: Bool? = nil) -> MaintenanceItem {
        var m = MaintenanceItem(id: Int.random(in: 1...9999), maintenanceTypeName: name)
        m.hoursUntilDue = hoursUntilDue.map { LooseNumber($0) }
        m.enabled = enabled
        return m
    }

    /// The exact input the two predicates disagreed on.
    func testAnItemWithNoEnabledFieldIsListed() {
        let unstated = item("Belt", hoursUntilDue: -5, enabled: nil)
        XCTAssertEqual(HardwareStore.serviceItems(from: [unstated]).count, 1,
                       "a nil `enabled` means Bambuddy did not say, not that it is off")
    }

    /// Explicitly off is the ONLY thing that hides a row.
    func testOnlyAnExplicitFalseIsHidden() {
        XCTAssertTrue(HardwareStore.serviceItems(from: [item("Belt", hoursUntilDue: -5, enabled: false)]).isEmpty)
        XCTAssertEqual(HardwareStore.serviceItems(from: [item("Belt", hoursUntilDue: -5, enabled: true)]).count, 1)
    }

    /// The invariant itself: anything triage counts as needing attention must be reachable in the
    /// list the user is sent to. Asserted over every combination of the field's three states.
    func testEverythingTriageFlagsIsAlsoListed() {
        for enabled in [nil, true, false] as [Bool?] {
            let row = item("Belt", hoursUntilDue: -5, enabled: enabled)
            let flagged = HardwareTriage.items(maintenance: [row], humidities: [], nozzlesKnown: true)
            let listed = HardwareStore.serviceItems(from: [row])
            XCTAssertEqual(!flagged.isEmpty, !listed.isEmpty,
                           "enabled: \(String(describing: enabled)) — triage and the list disagree")
        }
    }

    /// The sort is the reason this is a function and not a filter: due first, then warnings.
    func testDueSortsAboveWarningSortsAboveTheRest() {
        var due = item("Due", hoursUntilDue: -10); due.isDue = true
        var warn = item("Warn", hoursUntilDue: 5); warn.isWarning = true
        let calm = item("Calm", hoursUntilDue: 900)
        let order = HardwareStore.serviceItems(from: [calm, warn, due]).map(\.maintenanceTypeName)
        XCTAssertEqual(order, ["Due", "Warn", "Calm"])
    }
}

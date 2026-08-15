#if os(iOS)
// PrintActivityAttributes.ContentState, the APNs wire format.
// The subject is iOS-only (§6), so the tests are too — see
// docs/native-rewrite/18-mac-port-architecture.md for the count this removes on macOS.
import XCTest
@testable import Sprout

/// The countdown a Live Activity card renders.
///
/// This is guard logic, not cosmetics: the widget used to build `Date()...etaDate` directly, and
/// `...` calls `precondition(lowerBound <= upperBound)`, so an ETA that had slipped into the past
/// trapped the widget process and killed the card for the rest of the print. A content state is
/// sticky — the app stops updating it the moment it is suspended, and prints overrun their estimates
/// — so a past ETA at render time is the normal case, not a corner one.
final class PrintActivityCountdownTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func card(etaMinutesFromNow minutes: Double) -> PrintActivityAttributes.ContentState {
        var s = PrintActivityAttributes.ContentState()
        s.etaEpochMs = now.addingTimeInterval(minutes * 60).timeIntervalSince1970 * 1000
        return s
    }

    // MARK: - The regression

    /// The crash: a card pushed with 10 minutes left, re-rendered 15 minutes later.
    func testPastEtaIsOverdueRatherThanAnInvertedRange() {
        let stale = card(etaMinutesFromNow: 10)
        XCTAssertEqual(stale.countdown(now: now.addingTimeInterval(15 * 60)), .overdue)
    }

    /// Any offset either side of the ETA must resolve to something renderable — never a range whose
    /// lower bound is above its upper.
    func testNoOffsetEverProducesAnInvertedRange() {
        let eta = card(etaMinutesFromNow: 30)
        for minutes in stride(from: -600.0, through: 600.0, by: 7.5) {
            let renderTime = now.addingTimeInterval(minutes * 60)
            if case .ticking(let range) = eta.countdown(now: renderTime) {
                XCTAssertLessThanOrEqual(
                    range.lowerBound, range.upperBound,
                    "inverted range at \(minutes) min — this is the trap"
                )
            }
        }
    }

    // MARK: - Each outcome

    func testFutureEtaTicksFromNowToTheEta() {
        guard case .ticking(let range) = card(etaMinutesFromNow: 45).countdown(now: now) else {
            return XCTFail("a future ETA must tick")
        }
        XCTAssertEqual(range.lowerBound, now)
        XCTAssertEqual(range.upperBound.timeIntervalSince(now), 45 * 60, accuracy: 0.001)
    }

    /// `etaEpochMs == 0` is how "unknown" and "finished" are both encoded, and the slot has to stay
    /// empty rather than showing a fallback that implies a print is still running.
    func testNoEtaIsHidden() {
        XCTAssertEqual(PrintActivityAttributes.ContentState().countdown(now: now), .hidden)
    }

    func testExactlyExpiredIsOverdue() {
        XCTAssertEqual(card(etaMinutesFromNow: 0).countdown(now: now), .overdue)
    }

    func testOneSecondOfHeadroomStillTicks() {
        if case .ticking = card(etaMinutesFromNow: 1.0 / 60).countdown(now: now) { return }
        XCTFail("an ETA one second out is still a countdown")
    }

    // MARK: - Wire garbage

    /// Every field arrives as JSON from Trellis; a negative or non-finite ETA must not reach `Date`.
    func testNonsenseEtaValuesAreHidden() {
        let bogusValues: [Double] = [0, -1, -1_786_000_000_000, .nan, .infinity, -.infinity]
        for bogus in bogusValues {
            var s = PrintActivityAttributes.ContentState()
            s.etaEpochMs = bogus
            XCTAssertNil(s.etaDate, "etaDate should reject \(bogus)")
            XCTAssertEqual(s.countdown(now: now), .hidden, "countdown should hide \(bogus)")
        }
    }

    // MARK: - Fallback text

    /// The compact Dynamic Island slot is ~44pt wide; the roomy label would truncate there.
    func testOverdueLabelsAreDistinctAndTheCompactOneIsShorter() {
        XCTAssertFalse(LiveActivityCountdown.overdueLabel.isEmpty)
        XCTAssertFalse(LiveActivityCountdown.overdueLabelCompact.isEmpty)
        XCTAssertLessThan(
            LiveActivityCountdown.overdueLabelCompact.count,
            LiveActivityCountdown.overdueLabel.count
        )
    }

    // MARK: - The wire format is untouched

    /// `countdown()` and `etaDate` are computed, so they must not have added encoded keys — Trellis
    /// decodes this shape field for field.
    func testCountdownHelpersAddNoWireFields() throws {
        var s = PrintActivityAttributes.ContentState()
        s.etaEpochMs = 1_786_000_000_000
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
        let keys = Set(json?.keys ?? [:].keys)
        XCTAssertTrue(keys.contains("etaEpochMs"))
        XCTAssertFalse(keys.contains("countdown"))
        XCTAssertFalse(keys.contains("etaDate"))
    }
}
#endif

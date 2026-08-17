import XCTest
@testable import Sprout

/// When a status connection that has gone SILENT should be treated as dead.
///
/// The bug this closes was reported as "it says Complete but there's another print going", on a Mac
/// running build 29. What the printer actually reported at that moment was a job two prints old: the
/// app was rendering a frozen status object faithfully.
///
/// Both recovery paths the store already had key on the socket FAILING. A thrown error unwinds
/// `runSocketOnce`, `connected` flips, and `restartPolling`'s `guard !connected || socketDegraded`
/// lets the REST fallback run. But a socket that is merely dead never throws — `receive()` stays
/// parked, and that guard therefore REFUSES to poll. Nothing was left to notice the silence.
///
/// A Mac is where this bites: the app stays open across system sleep for hours, and the camera is a
/// separate connection that keeps working, so the window looks healthy while the status is hours old.
final class StatusStalenessTests: XCTestCase {

    private let threshold: Duration = .seconds(90)

    /// A frame that has just arrived is not stale, however the clock is read.
    func testAFreshFrameIsNotStale() {
        let now = ContinuousClock.now
        XCTAssertFalse(PrinterStatusStore.isStale(lastStatusAt: now, now: now, threshold: threshold))
    }

    /// Silence shorter than the threshold is tolerated — an idle printer genuinely has little to say,
    /// and a watchdog that fired on every quiet moment would close a working socket.
    func testShortSilenceIsTolerated() {
        let now = ContinuousClock.now
        XCTAssertFalse(PrinterStatusStore.isStale(lastStatusAt: now - .seconds(30),
                                                 now: now, threshold: threshold))
        XCTAssertFalse(PrinterStatusStore.isStale(lastStatusAt: now - .seconds(89),
                                                 now: now, threshold: threshold))
    }

    /// Past the threshold, the connection is dead as far as this store is concerned.
    func testSilencePastTheThresholdIsStale() {
        let now = ContinuousClock.now
        XCTAssertTrue(PrinterStatusStore.isStale(lastStatusAt: now - .seconds(91),
                                                now: now, threshold: threshold))
    }

    /// The boundary is exclusive: exactly at the threshold is not yet stale, so the rule cannot fire
    /// twice on one tick of a coarse clock.
    func testTheBoundaryIsExclusive() {
        let now = ContinuousClock.now
        XCTAssertFalse(PrinterStatusStore.isStale(lastStatusAt: now - .seconds(90),
                                                 now: now, threshold: threshold))
    }

    /// The case that was actually reported: hours of silence. Whatever else is arguable, this is not.
    func testHoursOfSilenceIsUnambiguouslyStale() {
        let now = ContinuousClock.now
        XCTAssertTrue(PrinterStatusStore.isStale(lastStatusAt: now - .seconds(8 * 3600),
                                                now: now, threshold: threshold))
    }

    /// A clock that has not moved cannot make anything stale — guards against a sign error that would
    /// close the socket on every watchdog tick.
    func testAStoppedClockNeverTrips() {
        let t = ContinuousClock.now
        for seconds in [0, 1, 90, 1000] {
            XCTAssertFalse(PrinterStatusStore.isStale(lastStatusAt: t, now: t,
                                                     threshold: .seconds(seconds)))
        }
    }

    /// A threshold of zero makes any elapsed time stale. Not a configuration the app uses, but it
    /// proves the comparison is on elapsed time rather than on the threshold's magnitude.
    func testAZeroThresholdMakesAnyElapsedTimeStale() {
        let now = ContinuousClock.now
        XCTAssertTrue(PrinterStatusStore.isStale(lastStatusAt: now - .milliseconds(1),
                                                now: now, threshold: .zero))
    }
}

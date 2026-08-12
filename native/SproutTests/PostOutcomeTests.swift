import XCTest
@testable import Sprout

/// The failure modes of a Trellis POST, and the words the device log uses for them.
///
/// These exist because of a real outage. Trellis's API-key gate raised an exception, so every
/// authenticated endpoint answered HTTP 500. The phone registered a card, got a 500, logged
/// NOTHING, and left the Live Activity frozen at 0 % for the whole print. The old return type was
/// `(ok: Bool, bound: Bool, reason: String?)`, and `(false, false, nil)` was returned for "no URL
/// configured", "the phone cannot reach the server" and "the server refused" alike — three
/// problems fixed in three different places, and the one NSLog on the path covered the fourth case
/// instead.
final class PostOutcomeTests: XCTestCase {

    // MARK: - the ok/bound/reason view the call sites use

    func testOnlyAStoredOutcomeIsOk() {
        XCTAssertTrue(PostOutcome.stored(bound: true).ok)
        XCTAssertTrue(PostOutcome.stored(bound: false).ok, "the server stored it; binding is a separate question")
        XCTAssertFalse(PostOutcome.misconfigured.ok)
        XCTAssertFalse(PostOutcome.unreachable.ok)
        XCTAssertFalse(PostOutcome.refused(status: 500, detail: nil).ok)
    }

    func testBoundIsFalseForEveryFailure() {
        // A registration is finalised on `ok && bound`. If a failure reported bound:true the card
        // would be marked done and never retried — frozen for the rest of the print.
        for outcome: PostOutcome in [.misconfigured, .unreachable, .refused(status: 500, detail: nil)] {
            XCTAssertFalse(outcome.bound, "\(outcome) must never look bound")
        }
    }

    func testReasonCarriesOnlyTheServersOwnDetail() {
        // `handle(refusal:)` acts on this string ("reattest_required" discards the local key). A
        // detail invented for a transport failure would trigger that recovery for a phone that is
        // merely offline.
        XCTAssertEqual(PostOutcome.refused(status: 403, detail: "reattest_required").reason, "reattest_required")
        XCTAssertNil(PostOutcome.unreachable.reason)
        XCTAssertNil(PostOutcome.misconfigured.reason)
        XCTAssertNil(PostOutcome.stored(bound: false).reason)
    }

    // MARK: - what gets written to the log

    func line(_ outcome: PostOutcome, path: String = "/register", token: String? = nil) -> String? {
        PostOutcome.logLine(path: path, token: token, outcome: outcome)
    }

    func testSuccessIsSilent() {
        XCTAssertNil(line(.stored(bound: true)), "this runs on a 4-second tick; a line per success is noise")
    }

    func testEachFailureSaysSomethingDifferent() {
        let messages = [
            line(.misconfigured), line(.unreachable),
            line(.refused(status: 500, detail: nil)), line(.stored(bound: false)),
        ].compactMap { $0 }

        XCTAssertEqual(messages.count, 4, "every non-success must produce a line")
        XCTAssertEqual(Set(messages).count, 4, "identical wording for different faults is the bug being fixed")
    }

    func testAServerFaultIsNotBlamedOnTheUser() {
        // The exact case that happened. A 5xx is Trellis's bug; sending someone to re-check their
        // API key or their URL over it costs them an hour.
        let msg = line(.refused(status: 500, detail: nil)) ?? ""

        XCTAssertTrue(msg.contains("500"), "the status is the one fact worth having: \(msg)")
        XCTAssertTrue(msg.lowercased().contains("trellis"), "name the faulty component: \(msg)")
        XCTAssertFalse(msg.lowercased().contains("api key"), "a 500 is not an auth problem: \(msg)")
    }

    func testARejectedKeyIsBlamedOnTheKey() {
        for status in [401, 403] {
            let msg = line(.refused(status: status, detail: nil))?.lowercased() ?? ""
            XCTAssertTrue(msg.contains("api key"), "HTTP \(status) is exactly the key case: \(msg)")
        }
    }

    func testAMissingUrlPointsAtSettingsNotTheNetwork() {
        let msg = line(.misconfigured)?.lowercased() ?? ""

        XCTAssertTrue(msg.contains("settings"), "nothing was sent; the fix is on the phone: \(msg)")
        XCTAssertFalse(msg.contains("http"), "no request was made, so there is no status to report: \(msg)")
    }

    func testUnreachableSaysNothingWasSent() {
        let msg = line(.unreachable)?.lowercased() ?? ""

        XCTAssertTrue(msg.contains("reach"), msg)
        XCTAssertFalse(msg.contains("api key"), "the key was never presented: \(msg)")
    }

    func testTheServersDetailIsIncludedWhenItSendsOne() {
        let msg = line(.refused(status: 403, detail: "reattest_required")) ?? ""
        XCTAssertTrue(msg.contains("reattest_required"), msg)
    }

    func testThePathAndTokenAppearSoTheLineIsActionable() {
        // Several tokens register on the same tick. Without both, a log line cannot be attributed to
        // a card, and "which one is stuck?" is unanswerable.
        let msg = line(.unreachable, path: "/register-start", token: "4089171fdeadbeef") ?? ""

        XCTAssertTrue(msg.contains("/register-start"), msg)
        XCTAssertTrue(msg.contains("4089171f"), msg)
        XCTAssertFalse(msg.contains("4089171fdeadbeef"), "log the prefix, not the whole push token")
    }

    func testAnAbsentTokenIsSimplyOmitted() {
        // /sync carries no single token.
        let msg = line(.unreachable, path: "/sync", token: nil) ?? ""
        XCTAssertTrue(msg.contains("/sync"), msg)
        XCTAssertFalse(msg.contains("nil"), msg)
    }
}

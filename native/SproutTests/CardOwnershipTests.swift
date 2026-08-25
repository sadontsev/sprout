import XCTest
@testable import Sprout

/// Who writes a Live Activity when the server that owns it cannot reach it.
///
/// The failure these exist for ran for thirteen days on a real deployment. A card started by push
/// carries its own update token, ActivityKit hands that token to a running process and to nobody
/// else, and the user had force-quit the app — so iOS never launched it, the token never reached
/// Trellis, and the relay refused every update as `not_bound`. The card sat on the lock screen at
/// the percentage its start push created, ETA counting down on the device, while Trellis, the app
/// and APNs all reported success.
///
/// The rule cannot be "write it whenever the server looks quiet": two writers hold different
/// snapshots off different clocks and the progress visibly jitters backwards. It has to be "write
/// it once the server has SAID it is not the writer" — an unconfirmed registration, or a token the
/// relay has listed in `needs_claim`.
final class CardOwnershipTests: XCTestCase {

    func testACardWhoseTokenNeverReachedTheServerIsOurs() {
        // The frozen-card case exactly: the card exists, nothing was ever handed over.
        XCTAssertTrue(LiveActivityController.appMustWrite(token: nil, registered: false, unbound: false))
        XCTAssertTrue(LiveActivityController.appMustWrite(token: "", registered: false, unbound: false))
    }

    func testAnUnconfirmedRegistrationIsOurs() {
        // Trellis answers `ok` for a registration it stored but could not bind. Reading that as
        // "the server has it" is what left the card frozen with every component reporting success.
        XCTAssertTrue(LiveActivityController.appMustWrite(token: "tok", registered: false, unbound: false))
    }

    func testATokenTheRelayRefusesIsOurs() {
        // `needs_claim` from /sync. The registration was accepted once; the binding is gone.
        XCTAssertTrue(LiveActivityController.appMustWrite(token: "tok", registered: true, unbound: true))
    }

    func testAConfirmedReachableCardIsTheServersAlone() {
        // The single-writer rule. This is the ONLY combination that gives the card back.
        XCTAssertFalse(LiveActivityController.appMustWrite(token: "tok", registered: true, unbound: false))
    }
}

import XCTest
@testable import Sprout

/// The vouch payload parsing is deliberately static and pure, because the alternative — asserting
/// on a UIKit delegate callback — only runs on a device, which is how this kind of code goes
/// untested and then fails silently in the one situation that matters: a silent push arriving while
/// the phone is locked in a pocket.
final class PushRegistrarTests: XCTestCase {
    func testAVouchNonceIsExtracted() {
        let payload: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "vouch_nonce": "nonce-1",
        ]

        XCTAssertEqual(PushRegistrar.vouchNonce(in: payload), "nonce-1")
        XCTAssertTrue(PushRegistrar.isVouch(payload))
    }

    func testAnOrdinaryAlertIsNotAVouch() {
        // A banner and a vouch arrive down the same pipe. Treating a banner as a vouch would feed
        // nonsense into a claim; treating a vouch as a banner would drop the only proof this device
        // can offer that it actually receives pushes on this token.
        let payload: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "✅ Printer — print finished", "body": "model.3mf"]],
        ]

        XCTAssertNil(PushRegistrar.vouchNonce(in: payload))
        XCTAssertFalse(PushRegistrar.isVouch(payload))
    }

    func testAnEmptyNonceIsNotANonce() {
        XCTAssertNil(PushRegistrar.vouchNonce(in: ["vouch_nonce": ""]))
    }

    func testAWrongTypeIsNotANonce() {
        XCTAssertNil(PushRegistrar.vouchNonce(in: ["vouch_nonce": 42]))
        XCTAssertNil(PushRegistrar.vouchNonce(in: [:]))
    }

    @MainActor
    func testAReceivedNonceIsHeldForTheNextClaim() {
        let registrar = PushRegistrar()
        var delivered: [String] = []
        registrar.onVouchNonce = { delivered.append($0) }

        registrar.handle(remoteNotification: ["vouch_nonce": "nonce-1"])

        XCTAssertEqual(delivered, ["nonce-1"], "the claim must be retried at once, not at the next registration")
        XCTAssertEqual(registrar.pendingVouchNonce, "nonce-1")
    }

    @MainActor
    func testTheNonceIsConsumedOnce() {
        // Single use at the relay too: a nonce that could be replayed would prove reachability once
        // and authorise binding forever.
        let registrar = PushRegistrar()
        registrar.handle(remoteNotification: ["vouch_nonce": "nonce-1"])

        XCTAssertEqual(registrar.consumeVouchNonce(), "nonce-1")
        XCTAssertNil(registrar.consumeVouchNonce())
    }

    @MainActor
    func testANonVouchPushLeavesTheHeldNonceAlone() {
        let registrar = PushRegistrar()
        registrar.handle(remoteNotification: ["vouch_nonce": "nonce-1"])
        registrar.handle(remoteNotification: ["aps": ["alert": "hello"]])

        XCTAssertEqual(registrar.pendingVouchNonce, "nonce-1")
    }
}

import XCTest
@testable import Sprout

/// Collects the bytes handed to each proof, across concurrency domains.
private final class ByteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(data)
    }

    var captured: [Data] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class ClaimBuilderTests: XCTestCase {
    private let identity = PairingIdentity(publicKey: "pub-1", deviceID: "dev-1")

    private func builder(
        proof: ClaimBuilder.AttestProof = .init(keyID: "attest-1", attestation: nil, assertion: "assert-bytes"),
        capture: (@Sendable (Data) -> Void)? = nil
    ) -> ClaimBuilder {
        ClaimBuilder(
            identity: identity,
            environment: .production,
            sign: { data in
                capture?(data)
                return "sig-over-\(data.count)-bytes"
            },
            attest: { data in
                capture?(data)
                return proof
            }
        )
    }

    func testAClaimCarriesEveryFieldCanopyChecks() async throws {
        let claim = try await builder().build(token: "tok-1", kind: .start, challenge: "chal-1")

        XCTAssertEqual(claim.token, "tok-1")
        XCTAssertEqual(claim.challenge, "chal-1")
        XCTAssertEqual(claim.pairingPublicKey, "pub-1")
        XCTAssertEqual(claim.deviceId, "dev-1")
        XCTAssertEqual(claim.bindingKind, "start")
        XCTAssertEqual(claim.apnsEnvironment, "production")
        XCTAssertEqual(claim.attestKeyId, "attest-1")
        XCTAssertEqual(claim.assertion, "assert-bytes")
        XCTAssertNil(claim.attestation)
    }

    func testTheTransmittedClientDataIsExactlyWhatWasSigned() async throws {
        // The hinge of the whole design. Canopy hashes the bytes it receives and verifies both
        // proofs against that hash — so if the app signed one encoding and transmitted another,
        // every claim would fail as attestation_invalid, indistinguishable from an attack.
        let recorder = ByteRecorder()
        let claim = try await builder(capture: { recorder.append($0) })
            .build(token: "tok-1", kind: .device, challenge: "chal-1", vouchNonce: "nonce-1")
        let signedBytes = recorder.captured

        let transmitted = try XCTUnwrap(Data(base64URLEncoded: claim.clientData))

        XCTAssertEqual(signedBytes.count, 2, "both proofs must be made over the client data")
        for bytes in signedBytes {
            XCTAssertEqual(bytes, transmitted, "a second encoding pass is the one thing that could make a genuine claim fail")
        }
    }

    func testTheClientDataContainsTheClaimedToken() async throws {
        let claim = try await builder().build(token: "tok-VICTIM", kind: .start, challenge: "c")
        let decoded = try XCTUnwrap(Data(base64URLEncoded: claim.clientData))
        let text = String(data: decoded, encoding: .utf8) ?? ""

        XCTAssertTrue(
            text.contains("tok-VICTIM"),
            "the token is inside the signed bytes, which is what stops a relay swapping it for "
            + "somebody else's after the fact"
        )
    }

    func testAVouchNonceIsCarriedWhenPresent() async throws {
        let claim = try await builder().build(token: "t", kind: .device, challenge: "c", vouchNonce: "nonce-1")

        XCTAssertEqual(claim.vouchNonce, "nonce-1")
        let text = String(data: try XCTUnwrap(Data(base64URLEncoded: claim.clientData)), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("nonce-1"), "the nonce must be signed over, not merely attached")
    }

    func testAnEmptyVouchNonceIsOmitted() async throws {
        let claim = try await builder().build(token: "t", kind: .start, challenge: "c", vouchNonce: "")

        XCTAssertNil(claim.vouchNonce, "Canopy compares the parsed value; empty is not absent")
        let text = String(data: try XCTUnwrap(Data(base64URLEncoded: claim.clientData)), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("vouch_nonce"))
    }

    func testAFirstUseAttestationIsCarriedInstead() async throws {
        let proof = ClaimBuilder.AttestProof(keyID: "k", attestation: "attest-bytes", assertion: nil)
        let claim = try await builder(proof: proof).build(token: "t", kind: .device, challenge: "c")

        XCTAssertEqual(claim.attestation, "attest-bytes")
        XCTAssertNil(claim.assertion, "Canopy refuses a claim carrying both proofs")
    }

    func testBindingKindIsCanopysNotTrellissKind() async throws {
        // Both travel in one request body: Canopy's activity/start/device, and Trellis's print/dry.
        // Conflating them would relabel a device row as an activity and collapse its retention.
        for kind in [ClaimBuilder.BindingKind.activity, .start, .device] {
            let claim = try await builder().build(token: "t", kind: kind, challenge: "c")
            XCTAssertEqual(claim.bindingKind, kind.rawValue)
        }
    }
}

final class PendingClaimsTests: XCTestCase {
    func testAddingATokenQueuesIt() {
        var q = PendingClaims()
        q.add(token: "tok-1", kind: .start)

        XCTAssertEqual(q.intents.count, 1)
        XCTAssertEqual(q.intents.first?.kind, "start")
    }

    func testAddingIsIdempotentByToken() {
        // The token streams re-emit; queueing twice would produce two claims for one token, each
        // burning a challenge.
        var q = PendingClaims()
        q.add(token: "tok-1", kind: .start)
        q.add(token: "tok-1", kind: .start)

        XCTAssertEqual(q.intents.count, 1)
    }

    func testAllThreeKindsAreQueued() {
        // Only /register used to retry. A start token whose first attempt failed was never
        // re-attempted for the rest of the process lifetime, which leaves the server with nothing
        // to push a start to and the lock screen empty for a whole print.
        var q = PendingClaims()
        q.add(token: "a", kind: .activity)
        q.add(token: "s", kind: .start)
        q.add(token: "d", kind: .device)

        XCTAssertEqual(Set(q.intents.map(\.kind)), ["activity", "start", "device"])
    }

    func testRemovingClearsIt() {
        var q = PendingClaims()
        q.add(token: "tok-1", kind: .start)
        q.remove(token: "tok-1")

        XCTAssertTrue(q.isEmpty)
    }

    func testAVouchNonceCanBeAttachedLater() {
        // The nonce arrives by silent push, after the intent was queued.
        var q = PendingClaims()
        q.add(token: "tok-1", kind: .device)
        q.attach(nonce: "nonce-1", to: "tok-1")

        XCTAssertEqual(q.intents.first?.vouchNonce, "nonce-1")
    }

    func testReQueueingKeepsAnAlreadyAttachedNonce() {
        var q = PendingClaims()
        q.add(token: "tok-1", kind: .device)
        q.attach(nonce: "nonce-1", to: "tok-1")
        q.add(token: "tok-1", kind: .device)

        XCTAssertEqual(q.intents.first?.vouchNonce, "nonce-1", "re-queueing must not discard the proof of reachability")
    }

    func testNeedsReclaimIsIntersectedAgainstHeldTokens() {
        // The security property. Read as a list of tokens to claim, this would be an attestation
        // oracle: a compromised server could name another user's token and have this device sign a
        // valid claim for it.
        let q = PendingClaims()
        let got = q.needingReclaim(serverSays: ["mine", "someone-elses"], heldTokens: ["mine"])

        XCTAssertEqual(got, ["mine"])
    }

    func testNeedsReclaimIsEmptyWhenTheDeviceHoldsNothing() {
        let q = PendingClaims()
        XCTAssertEqual(q.needingReclaim(serverSays: ["a", "b"], heldTokens: []), [])
    }

    func testEmptyTokensAreIgnored() {
        var q = PendingClaims()
        q.add(token: "", kind: .start)
        XCTAssertTrue(q.isEmpty)
    }

    func testPersistenceRoundTrips() {
        // The queue must survive a relaunch: an install whose first registration failed has nothing
        // else to remind it, since the token streams do not re-emit on a failed POST.
        var q = PendingClaims()
        q.add(token: "tok-1", kind: .device, vouchNonce: "n")
        q.add(token: "tok-2", kind: .start)

        let restored = PendingClaims.decoded(q.encoded())

        XCTAssertEqual(restored, q)
        XCTAssertEqual(restored.intents.first?.vouchNonce, "n")
    }

    func testGarbageDecodesToAnEmptyQueue() {
        XCTAssertTrue(PendingClaims.decoded(nil).isEmpty)
        XCTAssertTrue(PendingClaims.decoded(Data("nonsense".utf8)).isEmpty)
    }
}

/// The reconcile reply, which is how an unbound or dead card recovers without a human.
final class SyncReplyTests: XCTestCase {
    private func decode(_ json: String) throws -> LiveActivityController.SyncReply {
        try JSONDecoder().decode(LiveActivityController.SyncReply.self, from: Data(json.utf8))
    }

    func testTheSnakeCaseKeyIsRead() throws {
        // Trellis sends needs_claim. Decoding it as needsClaim silently yields an empty list, and an
        // empty list is indistinguishable from "nothing to do" — so the recovery path would look
        // wired, run every 30 seconds, and never do anything.
        let reply = try decode(#"{"end":[],"cards":["2"],"needs_claim":["tok-1"]}"#)

        XCTAssertEqual(reply.needsClaim, ["tok-1"])
    }

    func testOrphansAreRead() throws {
        let reply = try decode(#"{"end":["tok-gone"],"cards":[],"needs_claim":[]}"#)

        XCTAssertEqual(reply.end, ["tok-gone"])
    }

    func testMissingFieldsDefaultToEmptyRatherThanFailing() throws {
        // An older Trellis omits them. Failing to decode would take the ghost-card reconcile down
        // with the fields it does not know about, which is the more valuable half.
        let reply = try decode(#"{"cards":["2"]}"#)

        XCTAssertTrue(reply.end.isEmpty)
        XCTAssertTrue(reply.needsClaim.isEmpty)
    }

    func testTheReportNamesThisClientExplicitly() throws {
        // A card adopted through /sync is pushed to with this client's payload shape. Omitting it
        // adopts the card as expo, and an expo-shaped start reaches a native widget as a push APNs
        // accepts and the phone shows no card for.
        let report = LiveActivityController.SyncReport(tokens: ["a"], deviceId: "dev-1")
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(report)) as? [String: Any]

        XCTAssertEqual(json?["client"] as? String, "native")
        XCTAssertEqual(json?["deviceId"] as? String, "dev-1")
    }
}

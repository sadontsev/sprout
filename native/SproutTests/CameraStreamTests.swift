import XCTest
@testable import Sprout

/// Pure logic behind the camera stream's reconnect cadence, its end-of-connection frame flush and its
/// URL redaction. The concurrency fixes around these are not unit-testable, but the arithmetic and
/// the byte-level gate are, and both encode failures that cost real debugging time.
final class CameraStreamTests: XCTestCase {

    // MARK: - Reconnect cadence

    /// The camera self-terminates ~7 s after its last viewer, so the first retries must be fast
    /// enough to catch it still warm.
    func testEarlyAttemptsUseTheFastExponentialCadence() {
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 1), 0.4, accuracy: 0.0001)
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 2), 0.64, accuracy: 0.0001)
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 3), 1.024, accuracy: 0.0001)
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 4), 1.6384, accuracy: 0.0001)
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 5), 2.62144, accuracy: 0.0001)
    }

    func testTheCadenceIsMonotonicAcrossTheFastRange() {
        for n in 2...CameraReconnectPolicy.fastAttempts {
            XCTAssertGreaterThan(CameraReconnectPolicy.delay(forAttempt: n),
                                 CameraReconnectPolicy.delay(forAttempt: n - 1))
        }
    }

    /// The ceiling is the fix for the subscriber pile-up that starved the camera for every other
    /// client on the network: once a run of attempts has failed, back off hard.
    func testAttemptsPastTheFastRangeDropToTheCalmCadence() {
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 6), CameraReconnectPolicy.calmDelay)
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 7), CameraReconnectPolicy.calmDelay)
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 500), CameraReconnectPolicy.calmDelay)
        XCTAssertGreaterThan(CameraReconnectPolicy.calmDelay, CameraReconnectPolicy.fastCeiling)
    }

    func testNoFastDelayEverExceedsTheFastCeiling() {
        for n in 1...CameraReconnectPolicy.fastAttempts {
            XCTAssertLessThanOrEqual(CameraReconnectPolicy.delay(forAttempt: n),
                                     CameraReconnectPolicy.fastCeiling)
        }
    }

    /// `retryAttempt` is incremented before the lookup, so 0 and below are never asked for — but a
    /// negative exponent would produce a delay *shorter* than the first one, i.e. a tighter loop
    /// than the policy allows. Clamp rather than trust the caller.
    func testNonPositiveAttemptsClampToTheFirstDelay() {
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: 0), CameraReconnectPolicy.firstDelay)
        XCTAssertEqual(CameraReconnectPolicy.delay(forAttempt: -3), CameraReconnectPolicy.firstDelay)
    }

    // MARK: - End-of-connection frame flush

    private func jpeg(payload: [UInt8] = [0x00, 0x11, 0x22]) -> Data {
        Data([0xFF, 0xD8] + payload + [0xFF, 0xD9])
    }

    /// The on-demand camera can send one whole JPEG on a part with no Content-Length and then close.
    /// That frame is only provably complete at end-of-connection, and it used to be discarded.
    func testAWholeJpegIsAcceptedAtEndOfConnection() {
        XCTAssertTrue(MJPEGStreamClient.isCompleteJPEG(jpeg()))
    }

    func testTheSmallestPossibleJpegIsAccepted() {
        XCTAssertTrue(MJPEGStreamClient.isCompleteJPEG(Data([0xFF, 0xD8, 0xFF, 0xD9])))
    }

    /// A connection dropped mid-frame must NOT be flushed: handing the decoder a truncation would
    /// also report the stream as having gone live.
    func testATruncatedJpegIsRejected() {
        var d = jpeg()
        d.removeLast()
        XCTAssertFalse(MJPEGStreamClient.isCompleteJPEG(d))
    }

    func testABodyWithoutSoiIsRejected() {
        XCTAssertFalse(MJPEGStreamClient.isCompleteJPEG(Data([0x89, 0x50, 0xFF, 0xD9])))
    }

    func testEmptyAndRuntBodiesAreRejected() {
        XCTAssertFalse(MJPEGStreamClient.isCompleteJPEG(Data()))
        XCTAssertFalse(MJPEGStreamClient.isCompleteJPEG(Data([0xFF, 0xD8])))
        XCTAssertFalse(MJPEGStreamClient.isCompleteJPEG(Data([0xFF, 0xD8, 0xFF])))
    }

    /// `partBuffer` is sliced with `prefix`/`suffix` and re-emptied in place, so the check has to
    /// work on a Data whose indices do not start at zero.
    func testASlicedBufferIsJudgedByItsOwnBounds() {
        let framed = Data([0x0D, 0x0A]) + jpeg() + Data([0x0D, 0x0A])
        let body = framed.dropFirst(2).dropLast(2)
        XCTAssertTrue(MJPEGStreamClient.isCompleteJPEG(body))
        XCTAssertFalse(MJPEGStreamClient.isCompleteJPEG(framed))
    }

    // MARK: - Token redaction

    /// The camera stream token lives in the query string, so no log line may ever carry a raw URL.
    func testRedactionHidesTheStreamToken() {
        let url = URL(string: "https://example.invalid/api/v1/printers/1/camera/stream?token=SECRETVALUE&fps=10")!
        let out = MJPEGStreamClient.redact(url)
        XCTAssertFalse(out.contains("SECRETVALUE"))
        XCTAssertTrue(out.contains("token=***"))
        XCTAssertTrue(out.contains("fps=10"))
    }

    func testRedactionLeavesATokenlessUrlIntact() {
        let url = URL(string: "https://example.invalid/api/v1/printers/1/camera/stream")!
        XCTAssertEqual(MJPEGStreamClient.redact(url), "https://example.invalid/api/v1/printers/1/camera/stream")
    }

    // MARK: - Claiming the shared upstream at the fullscreen frame rate

    /// The backend fixes the upstream's `-r` from whichever viewer created it, so the fullscreen
    /// camera has to drop the tile's 2 fps upstream before it can start one of its own. It refuses
    /// while another viewer is attached, and that refusal is the retry signal.
    func testARefusedTeardownIsRetriedAndAClearedOneProceeds() {
        XCTAssertEqual(CameraUpstreamClaim.step(stopped: 0, skipped: true), .retry)
        XCTAssertEqual(CameraUpstreamClaim.step(stopped: 1, skipped: false), .proceed)
    }

    /// `stopped: 0` with no refusal means there was simply no upstream running — which is already
    /// the state we are trying to reach, so it must NOT be mistaken for a failure worth retrying.
    func testNothingToStopCountsAsSuccess() {
        XCTAssertEqual(CameraUpstreamClaim.step(stopped: 0, skipped: false), .proceed)
    }

    /// The attempt count is derived from the two tuning knobs rather than written down beside them,
    /// because a hand-maintained copy is what silently stops matching.
    func testThePollingScheduleStaysInsideItsBudget() {
        XCTAssertEqual(CameraUpstreamClaim.maxAttempts, 8)
        XCTAssertLessThanOrEqual(
            CameraUpstreamClaim.maxAttempts * CameraUpstreamClaim.pollIntervalMilliseconds,
            CameraUpstreamClaim.budgetMilliseconds)
        XCTAssertGreaterThan(CameraUpstreamClaim.maxAttempts, 1)
    }

    // MARK: - Picking the tile's frame rate from what the path costs

    /// An always-on thumbnail is the one surface that can quietly spend an allowance, so a metered or
    /// Low Data path drops it to a trickle. Both flags mean "these bytes cost the user", so either one
    /// alone is enough.
    func testAMeteredOrConstrainedPathDropsTheTileToATrickle() {
        XCTAssertEqual(CameraRate.tile(isExpensive: true, isConstrained: false), CameraRate.tileMetered)
        XCTAssertEqual(CameraRate.tile(isExpensive: false, isConstrained: true), CameraRate.tileMetered)
        XCTAssertEqual(CameraRate.tile(isExpensive: true, isConstrained: true), CameraRate.tileMetered)
    }

    func testAnUnmeteredPathGivesTheTileFullRate() {
        XCTAssertEqual(CameraRate.tile(isExpensive: false, isConstrained: false), CameraRate.tileUnmetered)
    }

    /// THE load-bearing coupling. `fullscreenNeedsFreshUpstream` decides whether to tear down and
    /// restart the shared upstream purely by comparing these two numbers, so if they ever drift apart
    /// the skip silently stops happening (a wasted camera restart on every fullscreen open) — or
    /// starts happening when it should not (fullscreen stuck on the tile's rate). Neither shows up as
    /// a failure anywhere else.
    func testTheUnmeteredTileMatchesFullscreen() {
        XCTAssertEqual(CameraRate.tileUnmetered, CameraRate.fullscreen)
        XCTAssertLessThan(CameraRate.tileMetered, CameraRate.fullscreen)
    }

    /// On wifi the tile already runs at the fullscreen rate, so whatever it started IS what we want and
    /// restarting it would only cost the user a warm-up in front of a black screen.
    func testFullscreenSkipsTheRestartWhenTheTileAlreadyMatchesIt() {
        let unmetered = CameraRate.tile(isExpensive: false, isConstrained: false)
        XCTAssertFalse(CameraRate.fullscreenNeedsFreshUpstream(tileFps: unmetered))
    }

    func testFullscreenClaimsAFreshUpstreamWhenTheTileStartedItSlower() {
        let metered = CameraRate.tile(isExpensive: true, isConstrained: false)
        XCTAssertTrue(CameraRate.fullscreenNeedsFreshUpstream(tileFps: metered))
    }

    /// A viewer already running FASTER than we would ask for is not a reason to restart anything —
    /// only a slower one is. Guards the comparison against being written as `!=`.
    func testAFasterExistingRateIsNotAReasonToRestart() {
        XCTAssertFalse(CameraRate.fullscreenNeedsFreshUpstream(tileFps: CameraRate.fullscreen + 5))
    }

    // MARK: - /camera/stop payload

    /// THE regression this type exists for. The backend answers the SUCCESS path with `{"stopped": n}`
    /// and omits `skipped` entirely; only the refusal path sends it. Decoding `skipped` as a
    /// non-optional `Bool` therefore threw on exactly the response that means the teardown worked,
    /// which would have sent the caller down its error path and straight back onto the 2 fps stream.
    func testSuccessPayloadDecodesWithoutASkippedKey() throws {
        let data = Data(#"{"stopped": 1}"#.utf8)
        let result = try JSONDecoder().decode(BambuddyClient.CameraStopResult.self, from: data)
        XCTAssertEqual(result.stopped, 1)
        XCTAssertFalse(result.skipped)
        XCTAssertEqual(CameraUpstreamClaim.step(stopped: result.stopped, skipped: result.skipped), .proceed)
    }

    func testRefusalPayloadDecodesAsSkipped() throws {
        let data = Data(#"{"stopped": 0, "skipped": true}"#.utf8)
        let result = try JSONDecoder().decode(BambuddyClient.CameraStopResult.self, from: data)
        XCTAssertEqual(result.stopped, 0)
        XCTAssertTrue(result.skipped)
        XCTAssertEqual(CameraUpstreamClaim.step(stopped: result.stopped, skipped: result.skipped), .retry)
    }

    /// An empty object is not worth throwing over: "nothing was stopped, nothing was refused" is a
    /// coherent reading, and the caller's next move on it — connect anyway — is the right one.
    func testAnEmptyPayloadDecodesToNeutralValues() throws {
        let result = try JSONDecoder().decode(BambuddyClient.CameraStopResult.self, from: Data("{}".utf8))
        XCTAssertEqual(result.stopped, 0)
        XCTAssertFalse(result.skipped)
    }
}

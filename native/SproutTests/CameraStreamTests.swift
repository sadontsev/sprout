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
}

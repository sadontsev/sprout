import XCTest
@testable import Sprout

#if os(macOS)

/// The camera window's window-free rules (§5.2, prototype `1c`).
///
/// All three of these encode a defect the owner hit on a real printer, and every one of them
/// compiled, ran and passed the suite in its broken form — the class of bug
/// `docs/native-rewrite/18-mac-port-architecture.md` opens with.
final class MacCameraWindowTests: XCTestCase {

    // MARK: - Pause must keep the picture

    /// The window's own comment promised "the window keeps its last frame" while paused. It did not:
    /// the stream view was handed `url: nil` and the default `holdLastFrameWhenInactive: false`, so
    /// `CameraNSView` ran `renderer.stop()` — `flushAndRemoveImage()` plus `frameStash.clear()`.
    /// Pause was really Stop-and-blank, and it destroyed the frame the Snapshot and Save buttons
    /// exist to hand out.
    func testPausingHoldsTheLastFrame() {
        let url = URL(string: "https://bambuddy.example/camera?fps=10")!
        let request = MacCameraStreamRequest.make(streamURL: url, paused: true)

        XCTAssertFalse(request.active)
        XCTAssertTrue(request.holdLastFrame)
    }

    /// The second half of the same bug, and the one that survives fixing `holdLastFrame` alone:
    /// `updateNSView` calls `setURL` BEFORE `setActive`, so a nil URL restarts a view that is still
    /// active and `restart()` with no URL stops the renderer unconditionally — one step before
    /// `holdLastFrame` can be consulted.
    func testPauseKeepsTheStreamUrl() {
        let url = URL(string: "https://bambuddy.example/camera?fps=10")!

        XCTAssertEqual(MacCameraStreamRequest.make(streamURL: url, paused: true).url, url)
        XCTAssertEqual(MacCameraStreamRequest.make(streamURL: url, paused: false).url, url)
    }

    func testResumingReactivatesTheSameUrl() {
        let url = URL(string: "https://bambuddy.example/camera?fps=10")!
        let request = MacCameraStreamRequest.make(streamURL: url, paused: false)

        XCTAssertTrue(request.active)
        XCTAssertEqual(request.url, url)
    }

    /// A missing camera token is not a pause. The view stays active and shows `noTokenNote` over the
    /// well; nothing here should quietly re-label it as paused.
    func testNoTokenLeavesTheViewActiveWithNoUrl() {
        let request = MacCameraStreamRequest.make(streamURL: nil, paused: false)

        XCTAssertNil(request.url)
        XCTAssertTrue(request.active)
    }

    // MARK: - "Is there a frame" is not "is the stream live"

    func testAFreshMountHasNoFrame() {
        var latch = MacCameraFrameLatch()
        XCTAssertFalse(latch.hasFrame)

        latch.note(isLive: true)
        latch.mount()
        XCTAssertFalse(latch.hasFrame, "a fresh mount is a fresh renderer with an empty stash")
    }

    func testTheFirstLiveEventRecordsAFrame() {
        var latch = MacCameraFrameLatch()
        latch.note(isLive: true)

        XCTAssertTrue(latch.hasFrame)
    }

    /// The defect: Snapshot and Save frame were gated on `cam.isLive`, so they went dead the instant
    /// the user paused — which is precisely when someone reaches for "save this frame". The latch is
    /// one-way for that reason. `MacPrinterInspector`'s tile carries the same correction.
    func testPausingDoesNotTakeTheFrameAway() {
        var latch = MacCameraFrameLatch()
        latch.note(isLive: true)
        latch.note(isLive: false)   // the renderer's `.connecting` on pause

        XCTAssertTrue(latch.hasFrame)
    }

    // MARK: - The badge

    /// `paused` is known on the click; `isLive` only falls when the renderer's event arrives. The
    /// old order left the badge claiming LIVE over a stream the user had already stopped.
    func testPausedWinsOverAStaleLiveFlag() {
        XCTAssertEqual(MacCameraBadge.label(isLive: true, paused: true), "PAUSED")
        XCTAssertEqual(MacCameraBadge.label(isLive: false, paused: true), "PAUSED")
    }

    func testLiveAndConnectingAreDistinguished() {
        XCTAssertEqual(MacCameraBadge.label(isLive: true, paused: false), "LIVE · MJPEG")
        XCTAssertEqual(MacCameraBadge.label(isLive: false, paused: false), "CONNECTING…")
    }
}

#endif

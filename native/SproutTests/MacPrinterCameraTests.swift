import XCTest
@testable import Sprout

#if os(macOS)

/// Where the chamber camera lives, and who is allowed to stream it.
///
/// This exists because of a defect the owner hit with a real printer: **the camera disappeared when
/// the window was narrowed.** §4 gives the camera to the Printer inspector, §1 auto-hides the
/// inspector below 1180 pt, and neither rule knew about the other — so a window narrowed by a few
/// points (or split-screened, or Stage Managed, or `⌥⌘I`-ed) simply lost the only live picture in
/// the app, with nothing on screen saying where it had gone.
///
/// The fix moves the camera into the content column when the inspector is not carrying it, which
/// creates a second thing that can stream one printer. That is the risk this file pins down:
/// Bambuddy runs ONE ffmpeg per printer and fixes its rate from whichever viewer created the
/// broadcaster, so two live tiles is not "two pictures" — it is one picture at someone else's frame
/// rate, paid for twice. `MacCameraPlacement` is the arbiter and every one of its answers is checked
/// here, because none of them is reachable from a test that cannot open a window.
final class MacPrinterCameraTests: XCTestCase {

    /// Both tile surfaces, so a rule can be asserted over the pair rather than once per case.
    private let surfaces: [MacCameraTileSurface] = [.inspector, .section]

    // MARK: - Placement

    /// The inspector keeps the camera when it is on screen — §4's placement is unchanged by the fix.
    func testTheInspectorHoldsTheCameraWhileItIsVisible() {
        XCTAssertEqual(MacCameraPlacement.owner(inspectorVisible: true), .inspector)
    }

    /// …and the content column takes it when the inspector is gone. This is the whole defect: the
    /// answer used to be "nowhere".
    func testTheSectionTakesTheCameraWhenTheInspectorIsHidden() {
        XCTAssertEqual(MacCameraPlacement.owner(inspectorVisible: false), .section)
    }

    // MARK: - Exactly one streamer

    /// **Exactly one** of the two tiles may stream, at either inspector visibility.
    ///
    /// Not "at least one" and not "at most one": the first would allow the disappearing camera back,
    /// and the second would allow the double stream. Both halves are the bug.
    func testExactlyOneTileStreamsAtEitherVisibility() {
        for visible in [true, false] {
            let streaming = surfaces.filter {
                MacCameraPlacement.mayStream(
                    surface: $0,
                    cameraPossible: true,
                    windowHasClaim: false,
                    inspectorVisible: visible
                )
            }
            XCTAssertEqual(streaming.count, 1, "inspectorVisible: \(visible) → \(streaming)")
        }
    }

    /// The tile that is NOT the owner stays silent even though it may still be mounted — SwiftUI
    /// keeps the inspector alive while its column animates away, so "am I on screen" is not the
    /// question, and answering it instead is how both tiles end up live for a second.
    func testAHiddenInspectorsTileDoesNotStream() {
        XCTAssertFalse(MacCameraPlacement.mayStream(
            surface: .inspector,
            cameraPossible: true,
            windowHasClaim: false,
            inspectorVisible: false
        ))
    }

    /// And the fallback stays silent while the inspector has the camera, so the section may render
    /// it without checking placement twice — it does check, but a second reading must agree.
    func testTheSectionsTileDoesNotStreamBehindAVisibleInspector() {
        XCTAssertFalse(MacCameraPlacement.mayStream(
            surface: .section,
            cameraPossible: true,
            windowHasClaim: false,
            inspectorVisible: true
        ))
    }

    // MARK: - The window still wins (§5.2)

    /// The camera WINDOW outranks both tiles, not just the one it was written against.
    ///
    /// The obvious way to get this wrong is to make the fallback a special case that "only appears
    /// when the inspector is hidden, so nothing else can be streaming" — which is false the moment
    /// the camera window is open, and the window is exactly where a user with a narrow main window
    /// would put the camera.
    func testTheCameraWindowOutranksBothTiles() {
        for surface in surfaces {
            for visible in [true, false] {
                XCTAssertFalse(MacCameraPlacement.mayStream(
                    surface: surface,
                    cameraPossible: true,
                    windowHasClaim: true,
                    inspectorVisible: visible
                ), "\(surface) at inspectorVisible: \(visible)")
            }
        }
    }

    /// `MacCameraOwnership` is where `windowHasClaim` comes from, and a PAUSED window holds no
    /// claim. Composed here rather than assumed, because the tile reads the arbiter through a
    /// negation and a flipped sense would silently mute both tiles forever.
    @MainActor
    func testAPausedCameraWindowHandsBothTilesBack() {
        let owner = MacCameraOwnership()
        owner.setWindowStreaming(true, printerId: 7)
        XCTAssertFalse(MacCameraPlacement.mayStream(
            surface: .section,
            cameraPossible: true,
            windowHasClaim: !owner.inspectorMayStream(printerId: 7),
            inspectorVisible: false
        ))

        owner.setWindowStreaming(false, printerId: 7)          // paused, still open
        XCTAssertTrue(MacCameraPlacement.mayStream(
            surface: .section,
            cameraPossible: true,
            windowHasClaim: !owner.inspectorMayStream(printerId: 7),
            inspectorVisible: false
        ))
    }

    /// The claim is per printer, so a camera window on printer 1 must not mute printer 2's fallback
    /// tile. Same rule the inspector already had; the fallback inherits it rather than re-deriving.
    @MainActor
    func testTheClaimStaysPerPrinterForTheFallbackTile() {
        let owner = MacCameraOwnership()
        owner.setWindowStreaming(true, printerId: 1)
        XCTAssertTrue(MacCameraPlacement.mayStream(
            surface: .section,
            cameraPossible: true,
            windowHasClaim: !owner.inspectorMayStream(printerId: 2),
            inspectorVisible: false
        ))
    }

    // MARK: - A picture has to be possible at all

    /// Moving the tile does not make a camera appear where there is none. The demo has no physical
    /// camera, and a connecting or offline printer has nothing to stream — the fallback must show
    /// the same stated absence the inspector did, not a tile stuck on "WAKING…".
    func testAnImpossibleCameraStreamsOnNeitherSurface() {
        for surface in surfaces {
            for visible in [true, false] {
                XCTAssertFalse(MacCameraPlacement.mayStream(
                    surface: surface,
                    cameraPossible: false,
                    windowHasClaim: false,
                    inspectorVisible: visible
                ), "\(surface) at inspectorVisible: \(visible)")
            }
        }
    }

    /// The states `cameraPossible` is fed from, tied to the placement so the pair is checked as the
    /// tile actually composes them: demo mode and a printer that is not answering yet.
    func testTheFallbackTileFollowsCameraPossible() {
        for kind in [DashKind.offline, .connecting] {
            XCTAssertFalse(MacPrinterCopy.cameraPossible(kind: kind, isDemo: false), "\(kind)")
            XCTAssertFalse(MacCameraPlacement.mayStream(
                surface: .section,
                cameraPossible: MacPrinterCopy.cameraPossible(kind: kind, isDemo: false),
                windowHasClaim: false,
                inspectorVisible: false
            ), "\(kind)")
        }
        XCTAssertFalse(MacCameraPlacement.mayStream(
            surface: .section,
            cameraPossible: MacPrinterCopy.cameraPossible(kind: .live, isDemo: true),
            windowHasClaim: false,
            inspectorVisible: false
        ), "the demo has no chamber camera")
        XCTAssertTrue(MacCameraPlacement.mayStream(
            surface: .section,
            cameraPossible: MacPrinterCopy.cameraPossible(kind: .live, isDemo: false),
            windowHasClaim: false,
            inspectorVisible: false
        ))
    }

    // MARK: - What the badge says on the fallback

    /// The fallback tile inherits `PLAYING IN WINDOW` rather than reading `PAUSED`.
    ///
    /// "The picture moved" and "the picture stopped" are different facts and only one of them
    /// invites a click that would take the claim back — the same distinction the inspector's badge
    /// was written for, checked here on the surface that did not exist when it was written.
    func testTheFallbackSaysWhereThePictureWentRatherThanPaused() {
        let claimed = true      // the camera window is streaming; `cameraPossible` is true
        XCTAssertEqual(
            MacPrinterCopy.cameraBadge(
                claimedByWindow: claimed,
                tileActive: MacCameraPlacement.mayStream(
                    surface: .section,
                    cameraPossible: true,
                    windowHasClaim: claimed,
                    inspectorVisible: false
                ),
                isLive: false,
                fps: 6
            ),
            "PLAYING IN WINDOW"
        )
    }

    /// And when the fallback genuinely owns the stream it reads as live, with the rate it latched.
    func testTheFallbackReadsLiveWhenItOwnsTheStream() {
        XCTAssertEqual(
            MacPrinterCopy.cameraBadge(
                claimedByWindow: false,
                tileActive: MacCameraPlacement.mayStream(
                    surface: .section,
                    cameraPossible: true,
                    windowHasClaim: false,
                    inspectorVisible: false
                ),
                isLive: true,
                fps: 12
            ),
            "LIVE · 12 fps"
        )
    }
}

#endif

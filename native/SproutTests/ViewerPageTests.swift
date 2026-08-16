import XCTest
@testable import Sprout

/// The two WKWebView-hosted viewers, and specifically their `compact` mode — the embedded preview
/// used inside the print wizard rather than the full-screen overlay.
///
/// Worth testing because every failure here is SILENT. The pages are JavaScript in a Swift string:
/// a typo does not fail the build, does not fail an existing test, and does not throw at runtime —
/// it renders a blank black rectangle, or the model at the wrong size, and only a human looking at
/// the screen notices. These assertions pin the parts that a refactor would quietly drop.
///
/// Background on why compact exists at all: a sliced file's `Metadata/plate_1.png` is written by
/// Bambu Studio, and the headless sidecar cannot initialise OpenGL (`glfwInit` error 65544 — no GPU,
/// no display, and its GLFW build asks for Wayland). So it emits a flat silhouette, and every sliced
/// file in the app was a shapeless blob in the filament colour. The app parses the G-code itself for
/// the full-screen viewer, so the preview now renders that instead of trusting the PNG.
final class ViewerPageTests: XCTestCase {
    private let plate = PlateSize(w: 350, d: 320)
    private let headers = ["X-API-Key": "test-key"]

    private func layer(compact: Bool) -> String {
        LayerPage.html(url: "https://example.test/gcode", headers: headers, plate: plate,
                       compact: compact)
    }

    // MARK: - Chrome

    /// Compact hides the layer slider and the reset button. Those are the full-screen viewer's
    /// controls; in a ~310pt tile they cover the model they exist to inspect.
    func testCompactHidesTheLayerChrome() {
        XCTAssertTrue(layer(compact: true).contains("#bar,#reset{display:none}"))
    }

    func testFullScreenKeepsTheLayerChrome() {
        XCTAssertFalse(layer(compact: false).contains("#bar,#reset{display:none}"))
    }

    /// The elements must still EXIST — the compact rule hides them by id, so renaming or removing
    /// one turns the rule into dead CSS and the control reappears over the preview.
    func testCompactTargetsElementsThatExist() {
        let html = layer(compact: true)
        XCTAssertTrue(html.contains("id=\"bar\""), "#bar must exist for the compact rule to hide it")
        XCTAssertTrue(html.contains("id=\"reset\""), "#reset must exist for the compact rule to hide it")
    }

    // MARK: - Framing

    /// `RESERVE` keeps the bottom of the canvas clear for the control card. Compact has no card, and
    /// reserving 150px of a short tile spent half the canvas on nothing: the model came out small and
    /// pushed high, which is what the first build of this preview actually looked like.
    func testCompactReservesNoRoomForAControlCardItDoesNotShow() {
        XCTAssertTrue(layer(compact: true).contains("var RESERVE=0,"))
    }

    func testFullScreenReservesRoomForItsControlCard() {
        XCTAssertTrue(layer(compact: false).contains("var RESERVE=150,"))
    }

    /// Compact fills more of its frame for the same reason: the full-screen value is conservative
    /// because the card overlaps the lower third.
    func testCompactFillsMoreOfTheFrame() {
        XCTAssertTrue(layer(compact: true).contains("FILL=0.46"))
        XCTAssertTrue(layer(compact: false).contains("FILL=0.33"))
    }

    /// Both constants feed one expression. If `fit` stops reading them the two tests above keep
    /// passing while the framing silently reverts.
    func testFitConsumesBothFramingConstants() {
        for compact in [true, false] {
            let html = layer(compact: compact)
            XCTAssertTrue(html.contains("Math.min(W,Hh-RESERVE)*FILL"),
                          "fit() must use RESERVE and FILL (compact: \(compact))")
        }
    }

    // MARK: - What the page is pointed at

    /// The G-code endpoints take the API key, not the camera stream token — the opposite of
    /// thumbnails. Dropping the header answers 401 and the viewer shows its failure copy.
    func testAuthHeadersReachThePage() {
        for compact in [true, false] {
            XCTAssertTrue(layer(compact: compact).contains("X-API-Key"))
        }
    }

    func testUrlAndPlateReachThePage() {
        let html = layer(compact: true)
        XCTAssertTrue(html.contains("https://example.test/gcode"))
        XCTAssertTrue(html.contains("{w:350,d:320}"))
    }

    /// Compact changes presentation only. A preview that fetched differently from the full-screen
    /// viewer would be a second code path to keep correct.
    func testCompactChangesOnlyPresentation() {
        let compact = layer(compact: true)
        let full = layer(compact: false)
        for shared in ["fetch(URL_, { headers: HDRS })", "https://example.test/gcode", "{w:350,d:320}"] {
            XCTAssertTrue(compact.contains(shared) && full.contains(shared),
                          "both modes must share: \(shared)")
        }
    }

    // MARK: - Injection

    /// `ViewerJS.literal` is the boundary between a Swift string and executing JavaScript. A URL is
    /// not attacker-controlled here, but it is user-controlled: a base URL with a quote in it would
    /// otherwise end the literal and break the page.
    func testUrlIsEscapedIntoTheJavaScriptLiteral() {
        let html = LayerPage.html(url: "https://example.test/a\"b", headers: headers, plate: plate,
                                  compact: true)
        XCTAssertFalse(html.contains("var URL_=\"https://example.test/a\"b\""),
                       "an unescaped quote would terminate the literal early")
    }

    // MARK: - The STL viewer's matching contract

    /// `StlModelView` has embedded unsliced models since before this change; the sliced half now
    /// behaves the same way. Pinned so the two do not drift apart.
    func testStlCompactAlsoHidesItsChrome() {
        let compact = StlPage.html(url: "https://example.test/f.stl", name: "f.stl", compact: true,
                                   headers: headers)
        let full = StlPage.html(url: "https://example.test/f.stl", name: "f.stl", compact: false,
                                headers: headers)
        XCTAssertNotEqual(compact, full, "compact must change the STL page too")
    }
}

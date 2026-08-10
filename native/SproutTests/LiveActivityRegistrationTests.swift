import XCTest
@testable import Sprout

/// The app's side of the SERVER-mode contract: the bodies and URLs handed to la-push, and the change
/// gate that decides what is worth a push. All of it is pure, so it is testable without ActivityKit.
///
/// This half of the contract is easy to get wrong silently — a card registered against a route that
/// does not exist, or under the wrong `kind`, still looks like success from inside the app and shows
/// up only as a lock-screen card frozen at 0 %.
final class LiveActivityRegistrationTests: XCTestCase {

    private func decode(_ data: Data?) throws -> [String: Any] {
        let raw = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    // MARK: - Endpoint

    func testEndpointIsBuiltOffThePushUrl() throws {
        XCTAssertEqual(
            LiveActivityController.endpoint("https://push.example.com", "/register")?.absoluteString,
            "https://push.example.com/register"
        )
    }

    /// `…/` + `/register` is `//register`, which the server answers 404 — and a swallowed 404 is
    /// indistinguishable from a working registration.
    func testEndpointStripsTrailingSlashes() {
        XCTAssertEqual(
            LiveActivityController.endpoint("https://push.example.com//", "/register-start")?.absoluteString,
            "https://push.example.com/register-start"
        )
    }

    func testEndpointIsNilWithoutAPushUrl() {
        XCTAssertNil(LiveActivityController.endpoint(nil, "/register"))
        XCTAssertNil(LiveActivityController.endpoint("", "/register"))
    }

    // MARK: - Token encoding

    func testTokenIsLowercaseHexWithLeadingZeros() {
        XCTAssertEqual(LiveActivityController.hex(Data([0x00, 0x0f, 0xa1, 0xff])), "000fa1ff")
        XCTAssertEqual(LiveActivityController.hex(Data()), "")
    }

    // MARK: - Registration bodies

    /// la-push's `Register` model is snake_case and requires `printer_id` + `push_token`.
    func testPrintCardRegistrationMatchesTheServersFieldNames() throws {
        let body = LiveActivityController.cardRegistration(
            attributes: PrintActivityAttributes(printerId: 7, amsId: nil),
            state: {
                var s = PrintActivityAttributes.ContentState()
                s.printerName = "H2C"
                s.iconUri = "file:///nozzle.png"
                return s
            }(),
            token: "abc123"
        )
        let json = try decode(LiveActivityController.encode(body))

        XCTAssertEqual(json["printer_id"] as? Int, 7)
        XCTAssertEqual(json["push_token"] as? String, "abc123")
        XCTAssertEqual(json["printer_name"] as? String, "H2C")
        XCTAssertEqual(json["icon_uri"] as? String, "file:///nozzle.png")
        XCTAssertEqual(json["kind"] as? String, "print")
        XCTAssertNil(json["ams_id"] as? Int, "a print card carries no AMS unit")
        // Without this the server falls back to the RN app's wire shape — a `{name, props}` content
        // state this app cannot decode — and every push is accepted by APNs and dropped on device.
        XCTAssertEqual(json["client"] as? String, "native")
    }

    /// The server keys drying cards `dry:<printerId>:<amsId>` off `kind` + `ams_id`. Registering a
    /// drying card as a print overwrites the print card's registration instead of adding one.
    func testDryingCardRegistersItsUnit() throws {
        let body = LiveActivityController.cardRegistration(
            attributes: PrintActivityAttributes(printerId: 7, amsId: 128),
            state: PrintActivityAttributes.ContentState(),
            token: "deadbeef"
        )
        let json = try decode(LiveActivityController.encode(body))

        XCTAssertEqual(json["kind"] as? String, "dry")
        XCTAssertEqual(json["ams_id"] as? Int, 128)
        XCTAssertEqual(json["printer_id"] as? Int, 7)
    }

    /// The name and glyph come from the card itself, never from the app's cache: in SERVER mode the
    /// server created the card and `/register` overwrites both fields, so posting our own idea of the
    /// name would blank a title the server had right.
    func testRegistrationEchoesTheCardsOwnNameAndGlyph() {
        var state = PrintActivityAttributes.ContentState()
        state.printerName = "Named by la-push"
        state.iconUri = "file:///glyph.png"
        let body = LiveActivityController.cardRegistration(
            attributes: PrintActivityAttributes(printerId: 1, amsId: nil),
            state: state,
            token: "t"
        )
        XCTAssertEqual(body.printerName, "Named by la-push")
        XCTAssertEqual(body.iconUri, "file:///glyph.png")
    }

    func testStartRegistrationMatchesTheServersFieldNames() throws {
        let json = try decode(LiveActivityController.encode(
            LiveActivityController.StartRegistration(pushToken: "p2s", iconUri: "")
        ))
        XCTAssertEqual(json["push_token"] as? String, "p2s")
        XCTAssertEqual(json["icon_uri"] as? String, "")
        // Decides the push-to-start attributes type. Wrong (or absent) means the server starts a
        // `LiveActivityAttributes` card, which this app never renders — no card at all.
        XCTAssertEqual(json["client"] as? String, "native")
    }

    // MARK: - Change gating

    /// The widget hides the whole layer row until `totalLayers > 0`, and Bambuddy commonly reports the
    /// total on a frame where nothing else moves — so leaving it out of the gate kept the row hidden
    /// until the first layer finished.
    func testLayerCountArrivingIsAChange() {
        var before = PrintActivityAttributes.ContentState()
        before.stateLabel = "Printing"
        var after = before
        after.totalLayers = 210

        XCTAssertTrue(LiveActivityController.meaningfulChange(from: before, to: after))
        XCTAssertFalse(LiveActivityController.meaningfulChange(from: after, to: after))
    }

    /// Every field the card renders participates, so a state flip that leaves the numbers alone still
    /// reaches the lock screen.
    func testRenderedFlagsCount() {
        let base = PrintActivityAttributes.ContentState()

        var finished = base
        finished.finished = true
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: base, to: finished))

        var tinted = base
        tinted.tint = LAColors.paused
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: base, to: tinted))

        var dual = base
        dual.hasNozzle2 = true
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: base, to: dual))

        var glyph = base
        glyph.iconUri = "file:///nozzle.png"
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: base, to: glyph))
    }
}

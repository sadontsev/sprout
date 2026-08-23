import XCTest
@testable import Sprout

/// What a push may tell the notification extension, and what it may not.
///
/// These matter more than most: the extension is the one part of this project that cannot be
/// exercised by a test at all — it is a separate process launched by iOS, on a device, on receipt of
/// a real push. Everything decidable had to be pulled out into `ShotHandoff` precisely so that it
/// could be checked here, and what is left in `NotificationService` is a URLSession call and a file
/// write.
final class ShotHandoffTests: XCTestCase {

    private func payload(_ shot: [String: Any]) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "t"], "mutable-content": 1], "sprout_shot": shot]
    }

    // MARK: - The token

    func testAWellFormedTokenIsAccepted() {
        XCTAssertEqual(ShotHandoff.token(in: payload(["t": "abc123-_XYZ", "p": 2])), "abc123-_XYZ")
    }

    /// The key is TOP LEVEL, beside `aps`. APNs hands `aps` to the system and everything else to
    /// the app verbatim, so a key nested inside it never arrives — and the symptom would be a
    /// banner with no picture, indistinguishable from the camera being off.
    func testAPayloadNestedInsideApsIsNotSeen() {
        let nested: [AnyHashable: Any] = ["aps": ["mutable-content": 1, "sprout_shot": ["t": "abc", "p": 2]]]
        XCTAssertNil(ShotHandoff.token(in: nested))
        XCTAssertNil(ShotHandoff.printerId(in: nested))
    }

    /// The token is interpolated into a query string. A value carrying `&`, `#` or a space would
    /// either change the request's shape or fail to parse, and Bambuddy mints tokens from a known
    /// alphabet — so anything outside it did not come from Bambuddy.
    func testATokenOutsideTheAlphabetIsRefused() {
        for bad in ["abc&def", "abc def", "abc#d", "abc/../d", "abc?x=1", "ab\nc", "abc\u{00e9}"] {
            XCTAssertNil(ShotHandoff.token(in: payload(["t": bad, "p": 2])), bad)
        }
    }

    func testAnEmptyOrOversizedTokenIsRefused() {
        XCTAssertNil(ShotHandoff.token(in: payload(["t": "", "p": 2])))
        XCTAssertNil(ShotHandoff.token(in: payload(["t": String(repeating: "a", count: 65), "p": 2])))
        XCTAssertNotNil(ShotHandoff.token(in: payload(["t": String(repeating: "a", count: 64), "p": 2])))
    }

    func testANonStringTokenIsRefused() {
        XCTAssertNil(ShotHandoff.token(in: payload(["t": 12345, "p": 2])))
        XCTAssertNil(ShotHandoff.token(in: ["aps": [:], "sprout_shot": "not a dictionary"]))
        XCTAssertNil(ShotHandoff.token(in: ["aps": [:]]))
    }

    // MARK: - The printer

    func testThePrinterIdIsRead() {
        XCTAssertEqual(ShotHandoff.printerId(in: payload(["t": "abc", "p": 2])), 2)
        XCTAssertEqual(ShotHandoff.printerId(in: payload(["t": "abc", "p": NSNumber(value: 7)])), 7)
    }

    func testANonPositivePrinterIdIsRefused() {
        XCTAssertNil(ShotHandoff.printerId(in: payload(["t": "abc", "p": 0])))
        XCTAssertNil(ShotHandoff.printerId(in: payload(["t": "abc", "p": -1])))
        XCTAssertNil(ShotHandoff.printerId(in: payload(["t": "abc"])))
    }

    // MARK: - The URL

    /// No URL crosses the wire. The host comes from the keychain the user typed it into and the
    /// path is compiled in, so the payload has no field that selects where the extension goes.
    func testTheUrlIsComposedFromTheStoredHost() {
        XCTAssertEqual(
            ShotHandoff.url(base: "https://bambuddy.example.com", printerId: 2, token: "abc")?.absoluteString,
            "https://bambuddy.example.com/api/v1/printers/2/camera/snapshot?token=abc")
    }

    func testTrailingSlashesOnTheStoredHostDoNotDoubleUp() {
        XCTAssertEqual(
            ShotHandoff.url(base: "https://bambuddy.example.com///", printerId: 9, token: "t")?.absoluteString,
            "https://bambuddy.example.com/api/v1/printers/9/camera/snapshot?token=t")
    }

    /// A stored base is user-typed. A `file:` or scheme-less value would otherwise send the
    /// extension somewhere nobody meant.
    func testANonHttpBaseIsRefused() {
        XCTAssertNil(ShotHandoff.url(base: "file:///etc/passwd", printerId: 2, token: "t"))
        XCTAssertNil(ShotHandoff.url(base: "bambuddy.example.com", printerId: 2, token: "t"))
        XCTAssertNil(ShotHandoff.url(base: "", printerId: 2, token: "t"))
        XCTAssertNil(ShotHandoff.url(base: "https://", printerId: 2, token: "t"))
    }

    func testPlainHttpIsAllowedBecauseALanBambuddyIsOftenPlainHttp() {
        XCTAssertNotNil(ShotHandoff.url(base: "http://192.168.31.10:8910", printerId: 2, token: "t"))
    }

    /// Belt and braces over the charset check: even if a token ever reached this function
    /// unvalidated, it is escaped rather than pasted.
    func testTheTokenIsEscapedIntoTheQuery() {
        let url = ShotHandoff.url(base: "https://h.example.com", printerId: 1, token: "a b&c")
        XCTAssertEqual(url?.query, "token=a%20b%26c")
    }

    // MARK: - The path is not steerable

    func testThePathIsCompiledInPerPrinter() {
        XCTAssertEqual(ShotHandoff.snapshotPath(printerId: 2), "/api/v1/printers/2/camera/snapshot")
        XCTAssertEqual(ShotHandoff.snapshotPath(printerId: 41), "/api/v1/printers/41/camera/snapshot")
    }
}

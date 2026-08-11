import SwiftUI
import XCTest
@testable import Sprout

final class FilamentColorTests: XCTestCase {

    func testNormAcceptsSixAndEightDigitHex() {
        XCTAssertEqual(FilamentColor.norm("565656"), "#565656")
        XCTAssertEqual(FilamentColor.norm("565656FF"), "#565656")
        XCTAssertEqual(FilamentColor.norm("#565656"), "#565656")
        XCTAssertEqual(FilamentColor.norm("565656ff"), "#565656", "case is normalised upward")
    }

    /// Alpha exactly "00" is Bambu's "unset" sentinel, not a real colour. Returning #000000 here
    /// made unknown-colour slots render as black filament, and in the wizard that black even beat
    /// the inventory spool's real colour.
    func testZeroAlphaIsUnsetNotBlack() {
        XCTAssertNil(FilamentColor.norm("00000000"))
        XCTAssertNil(FilamentColor.norm("FFFFFF00"))
    }

    /// Any other alpha is a genuine colour and keeps its RGB — the AMS reports e.g. "C9A38180".
    func testOtherAlphaKeepsItsColour() {
        XCTAssertEqual(FilamentColor.norm("C9A38180"), "#C9A381")
    }

    func testNonHexIsRejectedRatherThanMalformed() {
        XCTAssertNil(FilamentColor.norm("TRANSP"))
        XCTAssertNil(FilamentColor.norm("#GGGGGG"))
        XCTAssertNil(FilamentColor.norm(""))
        XCTAssertNil(FilamentColor.norm(nil))
        XCTAssertNil(FilamentColor.norm("12345"), "wrong length")
    }

    func testRelLuminanceEndpoints() {
        XCTAssertEqual(FilamentColor.relLuminance("#000000"), 0, accuracy: 0.0001)
        XCTAssertEqual(FilamentColor.relLuminance("#FFFFFF"), 1, accuracy: 0.0001)
    }

    func testContrastRatioIsSymmetricAndBounded() {
        let r = FilamentColor.contrastRatio("#000000", "#FFFFFF")
        XCTAssertEqual(r, 21, accuracy: 0.01)
        XCTAssertEqual(FilamentColor.contrastRatio("#FFFFFF", "#000000"), r, accuracy: 0.0001)
        XCTAssertEqual(FilamentColor.contrastRatio("#777777", "#777777"), 1, accuracy: 0.0001)
    }

    /// 0.179 is the luminance where black and white ink tie.
    func testInkFlipsAtTheTiePoint() {
        XCTAssertEqual(FilamentColor.inkOn("#FFFFFF"), Color(hex: 0x0D1012))
        XCTAssertEqual(FilamentColor.inkOn("#000000"), Color(hex: 0xFFFFFF))
        XCTAssertEqual(FilamentColor.inkOn(nil), Color(hex: 0xFFFFFF))
    }

    func testGreyscaleNames() {
        XCTAssertEqual(FilamentColor.name("#FFFFFF"), "White")
        XCTAssertEqual(FilamentColor.name("#F0F0F0"), "Off-white")
        XCTAssertEqual(FilamentColor.name("#B4B4B4"), "Light grey")
        XCTAssertEqual(FilamentColor.name("#808080"), "Grey")
        XCTAssertEqual(FilamentColor.name("#404040"), "Dark grey")
        XCTAssertEqual(FilamentColor.name("#000000"), "Black")
    }

    func testHueNames() {
        XCTAssertEqual(FilamentColor.name("#FF0000"), "Red")
        XCTAssertEqual(FilamentColor.name("#00AE42"), "Green")
        XCTAssertEqual(FilamentColor.name("#0A84FF"), "Blue")
    }

    /// Warm but washed-out should read as beige/brown, not "pale orange". The light/dark split is at
    /// L = 0.65, and the Pale/Dark qualifiers at 0.75 and 0.25 — so all three bands are covered.
    func testWashedOutWarmsBecomeBeigeOrBrown() {
        XCTAssertEqual(FilamentColor.name("#E8DCC8"), "Pale beige")
        XCTAssertEqual(FilamentColor.name("#C6B89E"), "Beige")
        XCTAssertEqual(FilamentColor.name("#5A4A38"), "Brown")
        XCTAssertEqual(FilamentColor.name("#3A2E22"), "Dark brown")
    }

    /// A saturated warm keeps its hue name — the beige/brown rule is for washed-out ones only.
    func testSaturatedWarmStaysOrange() {
        XCTAssertEqual(FilamentColor.name("#FF7A00"), "Orange")
    }

    func testNameRejectsMalformedInput() {
        XCTAssertNil(FilamentColor.name("565656"), "needs the # form")
        XCTAssertNil(FilamentColor.name(nil))
    }
}

final class ConfigRulesTests: XCTestCase {

    func testBaseUrlTrimsWhitespaceAndTrailingSlashes() {
        XCTAssertEqual(ConfigRules.sanitizeBaseUrl("  https://example.com/  "), "https://example.com")
        XCTAssertEqual(ConfigRules.sanitizeBaseUrl("https://example.com///"), "https://example.com")
        XCTAssertEqual(ConfigRules.sanitizeBaseUrl("https://exa mple.com"), "https://example.com")
    }

    func testApiKeyStripsPasteArtifacts() {
        XCTAssertEqual(ConfigRules.sanitizeApiKey("  bb_abc123  "), "bb_abc123")
        XCTAssertEqual(ConfigRules.sanitizeApiKey("bb_abc123\n"), "bb_abc123")
        XCTAssertEqual(ConfigRules.sanitizeApiKey("%bb_abc123%"), "bb_abc123")
    }

    /// Interior characters are never touched.
    func testApiKeyKeepsInteriorCharacters() {
        XCTAssertEqual(ConfigRules.sanitizeApiKey("bb_a-b_c123"), "bb_a-b_c123")
    }

    /// The sanitiser and the validator must share a charset. When they diverged — sanitize kept `_`
    /// but the validator only accepted alphanumerics — Connect stayed greyed out for any key with a
    /// `_` or `-` in it, despite the field being filled.
    func testValidatorAcceptsBase64UrlKeys() {
        XCTAssertTrue(ConfigRules.isValidApiKey("bb_abcdef"))
        XCTAssertTrue(ConfigRules.isValidApiKey("bb_a-b_c123456"))
        XCTAssertTrue(ConfigRules.isValidApiKey("  bb_a-b_c123456\n"))
    }

    func testValidatorRejectsNonKeys() {
        XCTAssertFalse(ConfigRules.isValidApiKey("abcdef"), "no bb_ prefix")
        XCTAssertFalse(ConfigRules.isValidApiKey("bb_abc"), "body shorter than 6")
        XCTAssertFalse(ConfigRules.isValidApiKey(""))
    }

    // MARK: - Push URL resolution

    private func config(baseUrl: String = "https://bambuddy.example.com", pushUrl: String? = nil, serverPush: Bool? = nil) -> AppConfig {
        var c = AppConfig()
        c.baseUrl = baseUrl
        c.pushUrl = pushUrl
        c.serverPush = serverPush
        return c
    }

    func testServerPushOffForcesLocal() {
        XCTAssertNil(ConfigRules.resolvePushUrl(config(serverPush: false)))
    }

    /// "Where is Trellis" is a different question from "should Live Activities be pushed through it".
    ///
    /// Trellis also serves MakerWorld collections — plain authenticated HTTP, no APNs — so turning
    /// Live-Activity push off must not take the Collections tab with it. That matters most for
    /// someone running a TestFlight build signed by a different Apple team: push cannot work for
    /// them at all, so switching it off is exactly right, and exactly when collections should stay.
    func testLaPushUrlSurvivesServerPushBeingOff() {
        XCTAssertEqual(
            ConfigRules.laPushUrl(config(pushUrl: "https://push.example.com/", serverPush: false)),
            "https://push.example.com"
        )
        XCTAssertEqual(ConfigRules.laPushUrl(config(serverPush: false)), "https://lapush.example.com")
        XCTAssertNil(ConfigRules.resolvePushUrl(config(serverPush: false)), "push itself stays off")
    }

    /// Everything else about the two must agree, or the app would reach one Trellis for cards and
    /// another for collections.
    func testTheTwoAgreeWheneverPushIsOn() {
        for cfg in [config(), config(pushUrl: "https://push.example.com"),
                    config(baseUrl: "https://example.com"), config(pushUrl: "ftp://nope.example.com")] {
            XCTAssertEqual(ConfigRules.resolvePushUrl(cfg), ConfigRules.laPushUrl(cfg))
        }
    }

    /// A malformed entry must not become a host the app then sends an API key to.
    func testLaPushUrlRejectsNonHttpSchemesToo() {
        XCTAssertNil(ConfigRules.laPushUrl(config(pushUrl: "ftp://push.example.com", serverPush: false)))
        XCTAssertNil(ConfigRules.laPushUrl(config(pushUrl: "not a url", serverPush: false)))
    }

    func testExplicitPushUrlWins() {
        XCTAssertEqual(
            ConfigRules.resolvePushUrl(config(pushUrl: "https://push.example.com/")),
            "https://push.example.com"
        )
    }

    func testDerivesFromTheBambuddySubdomain() {
        XCTAssertEqual(
            ConfigRules.resolvePushUrl(config()),
            "https://lapush.example.com"
        )
    }

    /// Was `testNoDerivationWithoutTheSubdomain`, and it pinned the bug rather than a requirement.
    ///
    /// Deriving nothing here meant no push AND no Collections tab for every deployment that did not
    /// use one person's `bambuddy.` DNS convention — an IP, a `.local` name, a plain hostname —
    /// while the settings field claimed the value was "derived from the server host". Both services
    /// normally share a box, so the host with Trellis's port is the right answer.
    func testDerivesTheTrellisPortWithoutTheSubdomain() {
        XCTAssertEqual(
            ConfigRules.resolvePushUrl(config(baseUrl: "https://example.com")),
            "https://example.com:8911"
        )
    }

    /// A malformed entry must silently disable push rather than POSTing a token somewhere unexpected.
    func testNonHttpSchemesAreRejected() {
        XCTAssertNil(ConfigRules.resolvePushUrl(config(pushUrl: "ftp://push.example.com")))
        XCTAssertNil(ConfigRules.resolvePushUrl(config(pushUrl: "not a url")))
    }

    func testTexturizeResolutionMirrorsPush() {
        var c = config()
        c.texturize = false
        XCTAssertNil(ConfigRules.resolveTexturizeUrl(c))

        c.texturize = true
        XCTAssertEqual(ConfigRules.resolveTexturizeUrl(c), "https://texturize.example.com")
    }
}

/// Where the app looks for Trellis when it has not been told.
///
/// The old rule swapped a `bambuddy.` subdomain for `lapush.` and returned nil for anything else —
/// one person's DNS convention. nil means no push AND no Collections tab, under a settings field
/// whose placeholder said the value was "derived from the server host". These are the addresses
/// people actually enter.
final class TrellisDerivationTests: XCTestCase {
    private func cfg(_ baseUrl: String, pushUrl: String? = nil) -> AppConfig {
        var c = AppConfig(baseUrl: baseUrl, apiKey: "k")
        c.pushUrl = pushUrl
        return c
    }

    func testALanAddressDerivesTheTrellisPort() {
        // Both services on one box is the overwhelmingly common deployment, and every one of these
        // returned nil before.
        XCTAssertEqual(ConfigRules.laPushUrl(cfg("http://192.168.1.50:8910")), "http://192.168.1.50:8911")
        XCTAssertEqual(ConfigRules.laPushUrl(cfg("http://<your-server>:8910")), "http://<your-server>:8911")
        XCTAssertEqual(ConfigRules.laPushUrl(cfg("https://printer.example.com")), "https://printer.example.com:8911")
    }

    func testABambuddySubdomainStillSwapsInstead() {
        // A tunnelled deployment has no port to swap: its companion is at lapush.example.com, not
        // bambuddy.example.com:8911. This rule must stay ahead of the port swap.
        XCTAssertEqual(ConfigRules.laPushUrl(cfg("https://bambuddy.example.com")), "https://lapush.example.com")
    }

    func testAnExplicitValueBeatsBothRules() {
        XCTAssertEqual(
            ConfigRules.laPushUrl(cfg("http://192.168.1.50:8910", pushUrl: "https://trellis.example.com/")),
            "https://trellis.example.com"
        )
    }

    func testAPathIsPreserved() {
        // A reverse proxy at https://host/bambuddy. Rebuilding through URLComponents would drop or
        // re-encode this, which is why the port swap is written by hand.
        XCTAssertEqual(
            ConfigRules.laPushUrl(cfg("https://host.example.com:8910/bambuddy")),
            "https://host.example.com:8911/bambuddy"
        )
    }

    func testAnIPv6LiteralIsNotMistakenForAPort() {
        // The colons inside brackets are address, not port. Splitting on the last colon without
        // this check would produce http://[2001:db8::1:8911 — unparseable, and the failure would
        // look like Trellis being down.
        XCTAssertEqual(
            ConfigRules.laPushUrl(cfg("http://[2001:db8::1]:8910")),
            "http://[2001:db8::1]:8911"
        )
        XCTAssertEqual(
            ConfigRules.laPushUrl(cfg("http://[2001:db8::1]")),
            "http://[2001:db8::1]:8911"
        )
    }

    func testGarbageStillDerivesNothing() {
        XCTAssertNil(ConfigRules.laPushUrl(cfg("not a url")))
        XCTAssertNil(ConfigRules.laPushUrl(cfg("ftp://host.example.com")))
    }

    func testTheDerivedPortIsTrellisOwn() {
        XCTAssertEqual(ConfigRules.trellisPort, 8911, "Bambuddy is 8910; a shared box puts Trellis at 8911")
    }
}

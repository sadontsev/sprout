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

    /// Warm but washed-out should read as beige/brown, not "pale orange".
    func testWashedOutWarmsBecomeBeigeOrBrown() {
        XCTAssertEqual(FilamentColor.name("#E8DCC8"), "Beige")
        XCTAssertEqual(FilamentColor.name("#5A4A38"), "Dark brown")
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

    func testNoDerivationWithoutTheSubdomain() {
        XCTAssertNil(ConfigRules.resolvePushUrl(config(baseUrl: "https://example.com")))
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

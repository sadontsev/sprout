import XCTest
@testable import Sprout

/// The `client_data` encoding is a contract with a Go service, and it is the one place where a
/// mismatch fails in the worst possible way: Canopy verifies the device's signature against the
/// exact bytes it receives, so a serialisation difference produces `attestation_invalid` on *every*
/// claim — indistinguishable from an attack in its logs, and undiagnosable from either side alone.
///
/// `testGoldenFixture` below asserts the encoding against a literal string. The identical literal
/// is asserted in Canopy's Go suite (`clientdata_test.go`). Two implementations that merely look
/// canonical will drift eventually; a shared fixture turns that drift into a red test in whichever
/// codebase moved.
final class ClaimDataTests: XCTestCase {
    private func sample(vouch: String? = nil) -> ClaimData {
        ClaimData(
            challenge: "chal-1",
            token: "tok-1",
            pairingPublicKey: "pub-1",
            deviceID: "dev-1",
            bindingKind: "device",
            apnsEnvironment: "production",
            vouchNonce: vouch
        )
    }

    // MARK: - the contract

    func testGoldenFixture() throws {
        let encoded = String(data: try sample().encoded(), encoding: .utf8)

        XCTAssertEqual(
            encoded,
            #"{"apns_environment":"production","binding_kind":"device","challenge":"chal-1","device_id":"dev-1","pairing_public_key":"pub-1","token":"tok-1"}"#,
            "this exact string is asserted in Canopy's Go suite too — if you changed the encoding, "
            + "change it there in the same commit or every claim will fail verification"
        )
    }

    func testGoldenFixtureWithAVouchNonce() throws {
        let encoded = String(data: try sample(vouch: "nonce-1").encoded(), encoding: .utf8)

        XCTAssertEqual(
            encoded,
            #"{"apns_environment":"production","binding_kind":"device","challenge":"chal-1","device_id":"dev-1","pairing_public_key":"pub-1","token":"tok-1","vouch_nonce":"nonce-1"}"#
        )
    }

    // MARK: - canonicalisation

    func testKeysAreSortedLexicographically() throws {
        let encoded = String(data: try sample().encoded(), encoding: .utf8) ?? ""
        let keys = encoded
            .split(separator: ",")
            .compactMap { $0.split(separator: ":").first }
            .map { $0.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "\"", with: "") }

        XCTAssertEqual(keys, keys.sorted(), "Go emits sorted map keys; Swift must match or the hashes differ")
    }

    func testThereIsNoWhitespace() throws {
        let encoded = String(data: try sample().encoded(), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(" "), "a pretty-printed encoding hashes differently")
        XCTAssertFalse(encoded.contains("\n"))
    }

    func testSlashesAreNotEscaped() throws {
        var data = sample()
        data.token = "a/b+c"
        let encoded = String(data: try data.encoded(), encoding: .utf8) ?? ""

        XCTAssertTrue(
            encoded.contains("a/b+c"),
            "Go leaves slashes alone. Swift escapes them by default, and base64url values avoid "
            + "them only by luck — a token that happened to contain one would fail verification."
        )
    }

    func testAnAbsentVouchNonceIsOmittedNotEmpty() throws {
        let encoded = String(data: try sample().encoded(), encoding: .utf8) ?? ""

        XCTAssertFalse(
            encoded.contains("vouch_nonce"),
            "Canopy compares the parsed value against the request field. An empty string is not the "
            + "same as an absent one, and the kinds that cannot be vouched send neither."
        )
    }

    func testAnEmptyVouchNonceIsTreatedAsAbsent() throws {
        let encoded = String(data: try sample(vouch: "").encoded(), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("vouch_nonce"))
    }

    func testEncodingIsStableAcrossCalls() throws {
        let first = try sample().encoded()
        let second = try sample().encoded()
        XCTAssertEqual(first, second, "dictionary iteration order must not leak into the bytes")
    }

    // MARK: - base64url

    func testBase64URLUsesTheURLAlphabetAndNoPadding() {
        // The whole protocol uses base64url. Padding or the standard alphabet here would be
        // accepted by Canopy's lenient decoder but would not match anything computed over it.
        let data = Data([251, 255, 190, 0])
        let encoded = data.base64URLEncodedString()

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: encoded), data)
    }

    func testBase64URLDecodingToleratesPaddingAndTheStandardAlphabet() {
        let raw = Data([251, 255, 190])
        let padded = raw.base64EncodedString() // standard alphabet, padded

        XCTAssertEqual(
            Data(base64URLEncoded: padded), raw,
            "clients differ on padding; a mismatch surfacing as a bad signature would be "
            + "indistinguishable from an attack"
        )
    }

    func testBase64URLDecodingRejectsGarbage() {
        XCTAssertNil(Data(base64URLEncoded: "!!! not base64 !!!"))
    }

    func testEncodedBase64RoundTrips() throws {
        let data = sample(vouch: "n")
        let wire = try data.encodedBase64()

        XCTAssertEqual(Data(base64URLEncoded: wire), try data.encoded())
    }
}

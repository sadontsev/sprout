import CryptoKit
import XCTest
@testable import Sprout

final class APNSEnvironmentTests: XCTestCase {
    private func profile(withEntitlement value: String?) -> Data {
        var entitlements = ""
        if let value {
            entitlements = "<key>aps-environment</key><string>\(value)</string>"
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
        """
        // A real profile is a CMS envelope wrapping the plist, so the parser has to find it inside
        // surrounding binary rather than decode the whole file.
        var data = Data([0x30, 0x82, 0x0A, 0xBC, 0x00, 0xFF])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0x01, 0x02]))
        return data
    }

    func testDevelopmentEntitlementMeansSandbox() {
        XCTAssertEqual(APNSEnvironment.from(profile: profile(withEntitlement: "development")), .sandbox)
    }

    func testProductionEntitlementMeansProduction() {
        XCTAssertEqual(APNSEnvironment.from(profile: profile(withEntitlement: "production")), .production)
    }

    func testAnAbsentProfileMeansProduction() {
        // App Store builds are the case with no development entitlement to find. Defaulting the
        // other way would send every real user's tokens to the sandbox gateway.
        XCTAssertEqual(APNSEnvironment.from(profile: nil), .production)
    }

    func testAnAbsentEntitlementMeansProduction() {
        XCTAssertEqual(APNSEnvironment.from(profile: profile(withEntitlement: nil)), .production)
    }

    func testGarbageIsSurvivable() {
        XCTAssertEqual(APNSEnvironment.from(profile: Data([0x00, 0x01, 0x02])), .production)
        XCTAssertEqual(APNSEnvironment.from(profile: Data("<?xml not really".utf8)), .production)
    }

    func testThePlistIsExtractedFromSurroundingBinary() {
        let data = profile(withEntitlement: "development")
        let plist = APNSEnvironment.extractPlist(from: data)

        XCTAssertNotNil(plist)
        XCTAssertTrue(String(data: plist!, encoding: .utf8)!.hasSuffix("</plist>"))
    }

    func testTheEnvironmentIsNotDerivedFromTheBuildConfiguration() {
        // The regression this file exists for. A Release build installed via Xcode is
        // development-signed, so its tokens are sandbox tokens while #if DEBUG is false — deriving
        // the environment from the compiler mislabels exactly that build, and the resulting
        // BadDeviceToken loop is silent at every layer.
        let development = APNSEnvironment.from(profile: profile(withEntitlement: "development"))
        XCTAssertEqual(development, .sandbox, "the entitlement decides, not the compiler")
    }
}

final class PairingIdentityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PairingStore.reset()
    }

    override func tearDown() {
        PairingStore.reset()
        super.tearDown()
    }

    func testAnIdentityIsCreatedOnFirstUse() throws {
        let identity = try PairingStore.loadOrCreate()

        XCTAssertFalse(identity.publicKey.isEmpty)
        XCTAssertFalse(identity.deviceID.isEmpty)
    }

    func testTheIdentityIsStable() throws {
        let first = try PairingStore.loadOrCreate()
        let second = try PairingStore.loadOrCreate()

        XCTAssertEqual(
            first, second,
            "the pairing key is the durable anchor: regenerating it would orphan every binding this "
            + "device already owns"
        )
    }

    func testTheDeviceIDIsNotGuessable() throws {
        let a = try PairingStore.loadOrCreate()
        PairingStore.reset()
        let b = try PairingStore.loadOrCreate()

        XCTAssertNotEqual(a.deviceID, b.deviceID)
        XCTAssertGreaterThanOrEqual(a.deviceID.count, 20, "16 random bytes, base64url")
    }

    func testThePublicKeyIsX963Uncompressed() throws {
        let identity = try PairingStore.loadOrCreate()
        let raw = Data(base64URLEncoded: identity.publicKey)

        XCTAssertNotNil(raw)
        XCTAssertEqual(raw?.count, 65, "1 tag byte plus two 32-byte coordinates")
        XCTAssertEqual(raw?.first, 4, "0x04 is the uncompressed-point tag Canopy requires")
    }

    func testSignaturesVerifyAgainstThePublishedPublicKey() throws {
        let identity = try PairingStore.loadOrCreate()
        let message = Data("client-data-bytes".utf8)

        let signature = try PairingStore.sign(message)

        let raw = try XCTUnwrap(Data(base64URLEncoded: identity.publicKey))
        let publicKey = try P256.Signing.PublicKey(x963Representation: raw)
        let parsed = try P256.Signing.ECDSASignature(
            derRepresentation: try XCTUnwrap(Data(base64URLEncoded: signature))
        )

        XCTAssertTrue(
            publicKey.isValidSignature(parsed, for: message),
            "the relay verifies with exactly this pair; if this fails, every claim fails"
        )
    }

    func testASignatureDoesNotVerifyOverDifferentBytes() throws {
        _ = try PairingStore.loadOrCreate()
        let identity = try XCTUnwrap(try PairingStore.load())
        let signature = try PairingStore.sign(Data("original".utf8))

        let raw = try XCTUnwrap(Data(base64URLEncoded: identity.publicKey))
        let publicKey = try P256.Signing.PublicKey(x963Representation: raw)
        let parsed = try P256.Signing.ECDSASignature(
            derRepresentation: try XCTUnwrap(Data(base64URLEncoded: signature))
        )

        XCTAssertFalse(
            publicKey.isValidSignature(parsed, for: Data("swapped".utf8)),
            "this is the property the whole relay design rests on: a claim signed for one token "
            + "must not verify after the token inside it is swapped for a victim's"
        )
    }

    func testTheSignatureIsDER() throws {
        _ = try PairingStore.loadOrCreate()
        let signature = try XCTUnwrap(Data(base64URLEncoded: try PairingStore.sign(Data("x".utf8))))

        XCTAssertEqual(
            signature.first, 0x30,
            "an ASN.1 SEQUENCE tag. Canopy verifies with ecdsa.VerifyASN1, so a raw r||s signature "
            + "would fail every claim"
        )
    }

    func testLoadReturnsNilBeforeAnyIdentityExists() throws {
        XCTAssertNil(try PairingStore.load())
    }

    func testSigningWithoutAnIdentityThrows() {
        XCTAssertThrowsError(try PairingStore.sign(Data("x".utf8)))
    }

    func testMigrationIsSafeToRunWhenNothingIsStored() {
        // Runs on every load, including the very first, so it must be a no-op rather than an error.
        PairingStore.migrateAccessibilityIfNeeded()
    }
}

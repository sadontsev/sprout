import XCTest
@testable import Sprout

/// The accessibility class of the stored config.
///
/// This is the credential without which the app can do nothing, and iOS wakes this app in the
/// background with the phone locked — a push-to-start, and the relay's silent vouch push. Under
/// `WhenUnlocked` the read fails at exactly those moments, `load()` returns nil, and the app falls
/// back to its onboarding gate. To whoever is holding the phone that does not look like a locked
/// keychain; it looks like the app threw the credentials away. Observed exactly that way.
final class SecureConfigAccessibilityTests: XCTestCase {
    private let config = AppConfig(baseUrl: "https://example.test", apiKey: "k-1")

    override func setUp() {
        super.setUp()
        SecureConfig.clear()
    }

    override func tearDown() {
        SecureConfig.clear()
        super.tearDown()
    }

    private func storedAccessibility() -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SecureConfig.serviceName,
            kSecAttrAccount: "bambu.config",
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess,
              let attrs = out as? [CFString: Any] else { return nil }
        return attrs[kSecAttrAccessible] as? String
    }

    // MARK: - Accessibility class — iOS only
    //
    // Not a port gap; the attribute has no meaning on macOS and asserting it there would be
    // asserting a fiction.
    //
    // macOS `SecItem*` uses the LEGACY file-based keychain unless an app opts into the
    // data-protection keychain with `kSecUseDataProtectionKeychain`. The legacy keychain predates
    // data protection and does not store `kSecAttrAccessible` at all, so these reads come back nil
    // there — which is exactly what the first macOS test run showed.
    //
    // Opting in was tried and reverted. It needs a `keychain-access-groups`/`application-identifier`
    // entitlement, which needs a Mac provisioning profile, which needs this App ID enabled for
    // macOS on the developer portal. Without it every keychain call fails `errSecMissingEntitlement`
    // (-34018) — the app cannot store credentials AT ALL, which is far worse than an unread
    // attribute.
    //
    // And the attribute is not what protects a Mac. The whole reason this app wants
    // `AfterFirstUnlock` is the LOCKED-DEVICE BACKGROUND WAKE-UP: a push-to-start, and the relay's
    // silent vouch push. §6 puts both on iOS only. A Mac app runs when its user is logged in, which
    // is precisely when the login keychain is unlocked, and the item is non-synchronizable either
    // way so it never reaches iCloud.
    //
    // What macOS DOES need — that the config round-trips, and that the migration never costs
    // someone their key — is covered by the unguarded cases below, and they pass there.
    #if os(iOS)
    func testAFreshlySavedConfigIsReadableWhileLocked() throws {
        SecureConfig.save(config)

        XCTAssertEqual(
            storedAccessibility(), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "WhenUnlocked makes the app unusable in exactly the background wake-ups it depends on"
        )
    }
    #endif

    func testTheConfigStillRoundTrips() throws {
        SecureConfig.save(config)
        let loaded = try XCTUnwrap(SecureConfig.load())

        XCTAssertEqual(loaded.baseUrl, config.baseUrl)
        XCTAssertEqual(loaded.apiKey, config.apiKey)
    }

    #if os(iOS)
    func testAnAlreadyOnboardedInstallIsMigrated() throws {
        // The population the change is for. Writing the constant only affects the ADD branch, so
        // without a migration every existing install keeps WhenUnlocked forever — and those are
        // precisely the installs that already have credentials worth not losing.
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SecureConfig.serviceName,
            kSecAttrAccount: "bambu.config",
            kSecValueData: try JSONEncoder().encode(config),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary, nil)
        XCTAssertEqual(storedAccessibility(), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        _ = SecureConfig.load()

        XCTAssertEqual(storedAccessibility(), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
    #endif

    func testMigrationPreservesTheStoredValue() throws {
        // A delete-then-add would briefly leave the device with no credentials at all, which is why
        // this is an in-place SecItemUpdate.
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SecureConfig.serviceName,
            kSecAttrAccount: "bambu.config",
            kSecValueData: try JSONEncoder().encode(config),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary, nil)

        let loaded = try XCTUnwrap(SecureConfig.load())

        XCTAssertEqual(loaded.apiKey, "k-1", "the migration must not cost the user their key")
    }

    func testMigrationOnAnEmptyKeychainIsHarmless() {
        SecureConfig.migrateAccessibilityIfNeeded()

        XCTAssertNil(SecureConfig.load(), "a fresh install has nothing to migrate and must not crash")
    }
}

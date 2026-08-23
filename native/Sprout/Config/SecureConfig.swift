import Foundation
import Security

/// App connection config, persisted in the iOS Keychain (this-device-only).
///
/// Field-for-field port of the RN app's `AppConfig` so a device that ran the RN build can be
/// migrated in place (see `SecureConfig.migrateFromExpoIfNeeded`).
struct AppConfig: Codable, Equatable, Sendable {
    /// e.g. https://bambuddy.example.com
    var baseUrl: String = ""
    /// Bambuddy scoped API key (bb_...) sent as X-API-Key
    var apiKey: String = ""
    /// Long-lived camera stream token, minted lazily
    var cameraToken: String?
    /// UI theme preference (defaults to system)
    var theme: String?
    /// Last-selected printer (restored on launch).
    var printerId: Int?
    var printerName: String?
    /// Trellis base URL for Live-Activity APNs push. Blank ⇒ derived from the bambuddy host as
    /// `lapush.*`; anyone self-hosting with a different host sets it explicitly.
    var pushUrl: String?
    /// Live-Activity mode. true/nil ⇒ register with Trellis so cards persist after the app is
    /// suspended + status banners fire. false ⇒ LOCAL only: cards update while the app runs.
    var serverPush: Bool?
    /// stl-texturize sidecar URL. Blank ⇒ derived from the bambuddy host as `texturize.*`.
    var texturizeUrl: String?
    /// Model-texturizer feature toggle. true/nil ⇒ enabled (URL derived or explicit, then
    /// health-probed). false ⇒ fully off.
    var texturize: Bool?
    /// Put a live camera frame on a halt notification. **Default off, and deliberately so.**
    ///
    /// A notification attachment is rendered on the lock screen, where anyone standing nearby sees
    /// it, and the frame is a photograph of the inside of the user's home. That is not a default
    /// anyone should acquire by installing an update, so `nil` means off and the user turns it on.
    var shotOnAlert: Bool?

    /// Optional Bambuddy ADMIN login — unlocks admin-gated actions (e.g. maintenance "mark done"),
    /// which categorically refuse API keys. Keychain-only, like the API key.
    var adminUsername: String?
    var adminPassword: String?

    var isComplete: Bool { !baseUrl.isEmpty && !apiKey.isEmpty }
}

/// Keychain-backed store for `AppConfig`.
///
/// `ThisDeviceOnly` throughout: the config never leaves the device and never lands in an
/// iCloud/iTunes backup. `AfterFirstUnlock` rather than `WhenUnlocked` — see `write`.
enum SecureConfig {
    /// The keychain service these items live under.
    ///
    /// It is the bundle id, and it is IDENTITY rather than configuration: change it and every
    /// existing install stops finding its stored base URL and API key — the app silently falls back
    /// to onboarding, exactly as if the credentials had been thrown away. A blanket rename of the
    /// bundle id across this repo did that to the tests, which is how the risk was found.
    ///
    /// Internal rather than private so tests can query the same value instead of restating it.
    static let serviceName = "com.mvks5.bambu"
    private static let service = serviceName
    private static let account = "bambu.config"

    static func load() -> AppConfig? {
        migrateAccessibilityIfNeeded()
        guard let data = read(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    /// Re-states the accessibility attribute on an item written before this app used
    /// `AfterFirstUnlock`.
    ///
    /// Changing the constant in `write` fixes nothing for anyone already onboarded: it is only set
    /// on the *add* branch, and the update branch deliberately never re-states it. Without this,
    /// every existing install keeps `WhenUnlocked` forever — which is exactly the population the
    /// change is for. Mirrors PairingStore.migrateAccessibilityIfNeeded.
    static func migrateAccessibilityIfNeeded() {
        _ = SecItemUpdate(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ] as CFDictionary,
            [kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        )
    }

    /// The account the BASE URL is mirrored to, in a keychain group the notification extension can
    /// also read.
    ///
    /// Only the base URL, and deliberately not the whole config: the extension needs to know which
    /// host to ask and nothing else, and the API key does not become reachable by a second binary
    /// just because a picture is wanted on a banner. The camera token it uses arrives in the push.
    ///
    /// **Its presence is the permission.** The item exists only while `shotOnAlert` is on, so the
    /// extension's question — "may I fetch a photograph, and from where?" — has exactly one answer
    /// to read. Storing the host and the consent separately would let them disagree, and the
    /// disagreement that matters is the one where the picture is taken anyway.
    static let sharedBaseUrlAccount = "bambu.baseurl"

    /// The app group, used as a keychain access group.
    ///
    /// Apple, *Sharing access to keychain items among a collection of apps*: "You can use app group
    /// names as keychain access group names, without adding them to the Keychain access groups
    /// entitlement." So the group the widget already shares is enough, and no new entitlement is
    /// introduced for this.
    static let sharedAccessGroup = LiveActivityArt.groupId

    static func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        write(data, service: service, account: account)
        // Mirrored on every save rather than written once at onboarding: a user who changes their
        // server would otherwise leave the extension pointing at the old one forever, and the
        // failure — a banner with no picture — says nothing about why. Turning the preference off
        // deletes it, which is what makes the item's presence mean consent.
        writeSharedBaseUrl(config.shotOnAlert == true ? config.baseUrl : "")
    }

    /// The base URL as the extension reads it. Nil when nothing has been onboarded.
    static func sharedBaseUrl() -> String? {
        guard let data = read(service: service, account: sharedBaseUrlAccount,
                              accessGroup: sharedAccessGroup),
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    private static func writeSharedBaseUrl(_ baseUrl: String) {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            SecItemDelete([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: sharedBaseUrlAccount,
                kSecAttrAccessGroup: sharedAccessGroup,
            ] as CFDictionary)
            return
        }
        write(data, service: service, account: sharedBaseUrlAccount, accessGroup: sharedAccessGroup)
    }

    static func clear() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
        // The mirror goes with it. Signing out and leaving a second binary holding the old host is
        // the kind of residue nobody looks for.
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: sharedBaseUrlAccount,
            kSecAttrAccessGroup: sharedAccessGroup,
        ] as CFDictionary)
    }

    // MARK: - Keychain primitives

    private static func read(service: String, account: String, accessGroup: String? = nil) -> Data? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ data: Data, service: String, account: String,
                             accessGroup: String? = nil) {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        // Update-then-add: SecItemAdd fails with errSecDuplicateItem on an existing entry, and
        // delete-then-add would briefly leave the device with no credentials at all.
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            // AfterFirstUnlock, not WhenUnlocked. This item is the base URL and API key — without
            // it the app can do nothing at all — and iOS wakes this app in the background with the
            // phone locked: a push-to-start, and the relay's silent vouch push. A WhenUnlocked read
            // fails at exactly those moments, `load()` returns nil, and the app falls back to its
            // onboarding gate. That does not look like a locked keychain to whoever is holding the
            // phone; it looks like the app threw the credentials away.
            //
            // PairingIdentity hit this and was moved to AfterFirstUnlock. This file, holding the
            // more important secret, was left behind — the fix applied to one of two siblings.
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

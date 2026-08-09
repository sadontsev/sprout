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
    /// la-push base URL for Live-Activity APNs push. Blank ⇒ derived from the bambuddy host as
    /// `lapush.*`; anyone self-hosting with a different host sets it explicitly.
    var pushUrl: String?
    /// Live-Activity mode. true/nil ⇒ register with la-push so cards persist after the app is
    /// suspended + status banners fire. false ⇒ LOCAL only: cards update while the app runs.
    var serverPush: Bool?
    /// stl-texturize sidecar URL. Blank ⇒ derived from the bambuddy host as `texturize.*`.
    var texturizeUrl: String?
    /// Model-texturizer feature toggle. true/nil ⇒ enabled (URL derived or explicit, then
    /// health-probed). false ⇒ fully off.
    var texturize: Bool?
    /// Optional Bambuddy ADMIN login — unlocks admin-gated actions (e.g. maintenance "mark done"),
    /// which categorically refuse API keys. Keychain-only, like the API key.
    var adminUsername: String?
    var adminPassword: String?

    var isComplete: Bool { !baseUrl.isEmpty && !apiKey.isEmpty }
}

/// Keychain-backed store for `AppConfig`.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` matches the RN build: the config never leaves the
/// device and never lands in an iCloud/iTunes backup.
enum SecureConfig {
    private static let service = "com.mvks5.bambu"
    private static let account = "bambu.config"

    static func load() -> AppConfig? {
        guard let data = read(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    static func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        write(data, service: service, account: account)
    }

    static func clear() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }

    // MARK: - Keychain primitives

    private static func read(service: String, account: String) -> Data? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ data: Data, service: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        // Update-then-add: SecItemAdd fails with errSecDuplicateItem on an existing entry, and
        // delete-then-add would briefly leave the device with no credentials at all.
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

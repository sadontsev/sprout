import CryptoKit
import Foundation
import Security

/// The device half of push-token ownership: a signing keypair and a device id.
///
/// A keypair rather than a shared secret, deliberately. A secret has to travel to the relay on
/// every claim, so a compromised companion service — or a LAN observer on a plain-HTTP deployment —
/// could replay it and seize the binding. Nothing secret leaves this device: the relay sees a
/// signature over a single-use, tenant-bound challenge that it can neither reuse nor alter.
///
/// This is the *durable* anchor. An App Attest key dies with every reinstall; this one survives in
/// the Keychain, which is what lets a reinstalled app prove it is the same install.
struct PairingIdentity: Equatable {
    /// Base64url X9.63 uncompressed point — the form Canopy digests and stores.
    var publicKey: String
    /// Which phone. Minted here rather than by the server so it exists before any registration of
    /// any kind, including installs that never start a Live Activity.
    var deviceID: String
}

/// Stores the pairing key and device id, and signs claims with them.
///
/// Deliberately separate from `AppConfig`: signing out or re-onboarding must not destroy the
/// identity that owns this device's push bindings.
enum PairingStore {
    static let service = "com.mvks5.bambu"
    static let account = "bambu.pairing"

    enum Failure: Error, Equatable {
        case keychain(OSStatus)
        case malformedStoredKey
    }

    // MARK: - reading

    /// Loads the identity, creating one on first use.
    static func loadOrCreate() throws -> PairingIdentity {
        if let existing = try load() {
            return existing
        }
        return try create()
    }

    static func load() throws -> PairingIdentity? {
        guard let stored = try loadStored() else { return nil }
        return PairingIdentity(
            publicKey: stored.privateKey.publicKey.x963Representation.base64URLEncodedString(),
            deviceID: stored.deviceID
        )
    }

    // MARK: - signing

    /// Signs `data` with the pairing key, returning the base64url DER signature.
    ///
    /// DER because that is what `SecKeyCreateSignature` with
    /// `ecdsaSignatureMessageX962SHA256` produces and what Canopy's `ecdsa.VerifyASN1` expects —
    /// choosing anything else would mean one side re-encoding, and an encoding contract that fails
    /// silently is the hazard this protocol already documents for `client_data`.
    static func sign(_ data: Data) throws -> String {
        guard let stored = try loadStored() else { throw Failure.malformedStoredKey }
        let signature = try stored.privateKey.signature(for: data)
        return signature.derRepresentation.base64URLEncodedString()
    }

    // MARK: - creation and migration

    private struct Stored {
        var privateKey: P256.Signing.PrivateKey
        var deviceID: String
    }

    private struct Blob: Codable {
        var privateKey: Data
        var deviceID: String
    }

    private static func create() throws -> PairingIdentity {
        let key = P256.Signing.PrivateKey()
        var deviceBytes = Data(count: 16)
        _ = deviceBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let deviceID = deviceBytes.base64URLEncodedString()

        let blob = Blob(privateKey: key.rawRepresentation, deviceID: deviceID)
        try write(try JSONEncoder().encode(blob))

        return PairingIdentity(
            publicKey: key.publicKey.x963Representation.base64URLEncodedString(),
            deviceID: deviceID
        )
    }

    private static func loadStored() throws -> Stored? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure.keychain(status)
        }

        migrateAccessibilityIfNeeded()

        guard
            let blob = try? JSONDecoder().decode(Blob.self, from: data),
            let key = try? P256.Signing.PrivateKey(rawRepresentation: blob.privateKey)
        else { throw Failure.malformedStoredKey }

        return Stored(privateKey: key, deviceID: blob.deviceID)
    }

    private static func write(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // AfterFirstUnlock, not WhenUnlocked: the canonical moment this is needed is a
            // push-to-start arriving while the phone is locked in a pocket. iOS grants background
            // runtime there, and a WhenUnlocked read fails at exactly that moment — so the claim
            // never leaves the device and the remotely-started card freezes at its start content.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        } else if updated != errSecSuccess {
            throw Failure.keychain(updated)
        }
    }

    /// Re-states the accessibility attribute on an item written before this app used
    /// `AfterFirstUnlock`.
    ///
    /// Changing the constant above fixes nothing for anyone already onboarded: `kSecAttrAccessible`
    /// is only set on the *add* branch, and the update branch deliberately never re-states it (a
    /// delete-then-add would briefly leave the device with no credentials at all). Without this
    /// migration every existing install keeps `WhenUnlocked` forever — which is precisely the
    /// population the change is for.
    static func migrateAccessibilityIfNeeded() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // The attributes dictionary of SecItemUpdate accepts kSecAttrAccessible, so this needs no
        // delete and no re-add.
        _ = SecItemUpdate(
            query as CFDictionary,
            [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        )
    }

    /// Removes the identity. The reset-pairing path, and what tests use to start clean.
    static func reset() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

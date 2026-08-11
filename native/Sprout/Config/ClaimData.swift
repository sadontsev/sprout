import Foundation

/// The bytes a device signs when it claims a push token.
///
/// This is the cross-language contract with Canopy, and the one place where a mistake fails in the
/// worst possible way: the relay verifies the signature against the exact bytes it receives, so a
/// serialisation difference between Swift and Go produces `attestation_invalid` on *every* claim —
/// indistinguishable from an attack in the relay's logs, and impossible to diagnose from either side
/// alone.
///
/// Two rules keep that from happening:
///
/// 1. **The bytes travel verbatim.** The app sends the encoded JSON as base64 alongside the claim;
///    Canopy hashes what it received and then checks that the fields *parsed out of it* match the
///    request's top-level fields. Nothing re-serialises. WebAuthn transmits `clientDataJSON` for the
///    same reason.
/// 2. **The encoding is pinned by a golden fixture**, asserted in both test suites against the same
///    literal string. Two implementations that merely "look canonical" will differ eventually; a
///    fixture makes the drift a red test rather than a production outage.
///
/// Canonical form: UTF-8 JSON, keys sorted lexicographically, no whitespace, no escaped slashes,
/// absent optionals omitted entirely rather than encoded as null.
struct ClaimData: Equatable {
    /// The single-use nonce Canopy issued for this claim.
    var challenge: String
    /// The push token being claimed.
    var token: String
    /// The device's long-lived pairing public key, base64url X9.63.
    var pairingPublicKey: String
    /// Which phone. Minted on device so it exists before any registration.
    var deviceID: String
    /// `activity`, `start` or `device` — Canopy's kind, which is not the service's
    /// `print`/`dry` kind. Both travel in the same request body.
    var bindingKind: String
    /// `sandbox` or `production`, derived from the aps-environment entitlement.
    var apnsEnvironment: String
    /// Echoed back from the silent push that proves this device receives pushes on this token.
    /// Only device tokens can be vouched, so it is absent for the other kinds — and absent means
    /// *omitted*, never an empty string, because the relay compares the parsed value.
    var vouchNonce: String?

    /// The exact bytes to sign and transmit.
    func encoded() throws -> Data {
        var fields: [String: String] = [
            "apns_environment": apnsEnvironment,
            "binding_kind": bindingKind,
            "challenge": challenge,
            "device_id": deviceID,
            "pairing_public_key": pairingPublicKey,
            "token": token,
        ]
        if let vouchNonce, !vouchNonce.isEmpty {
            fields["vouch_nonce"] = vouchNonce
        }

        // sortedKeys and withoutEscapingSlashes are both load-bearing: Go's encoder emits sorted map
        // keys and leaves slashes alone, and base64url values contain no slashes only by luck.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(fields)
    }

    /// The encoded bytes, base64url without padding — the wire form of `client_data`.
    func encodedBase64() throws -> String {
        try encoded().base64URLEncodedString()
    }
}

extension Data {
    /// base64url without padding, which is what every other identifier in this protocol uses.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url, tolerating padding and the standard alphabet. Clients differ, and a
    /// padding mismatch surfacing as a bad signature would be indistinguishable from an attack.
    init?(base64URLEncoded input: String) {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}

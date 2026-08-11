#if DEBUG
import CryptoKit
import DeviceCheck
import Foundation

/// Captures a real App Attest attestation and prints it, so the relay's verification can be checked
/// against bytes Apple actually produced.
///
/// The relay's procedure is tested exhaustively against a synthetic Apple-shaped chain — every
/// rejection path — but fixtures produced and parsed by the same codebase would agree even if both
/// were wrong about the real encoding. Only a genuine attestation settles that, and only a physical
/// device can make one. This is the smallest thing that produces one.
///
/// DEBUG-only and opt-in: it burns an App Attest key, and Apple throttles key generation and uses
/// it to build a per-device risk metric.
enum AttestCapture {
    /// Fixed so the verifier can reconstruct the exact bytes. The relay hashes what it receives and
    /// derives the nonce from `SHA-256(authData || SHA-256(clientData))`, so the *contents* are
    /// irrelevant to the crypto — what matters is that both sides use the identical bytes.
    static let clientData = Data("canopy-attest-capture-v1".utf8)

    /// Set `-AttestCapture YES` in the scheme, or `UserDefaults.standard.set(true, forKey:)`.
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "AttestCapture") }

    static func runIfRequested() {
        guard isRequested else { return }
        Task { await run() }
    }

    static func run() async {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            NSLog("[attest-capture] unsupported on this device")
            return
        }

        do {
            let keyID = try await service.generateKey()
            let hash = Data(SHA256.hash(data: clientData))
            let attestation = try await service.attestKey(keyID, clientDataHash: hash)

            // Written to a file rather than logged. The console truncates long lines, and a
            // truncated attestation is indistinguishable from a malformed one at the far end —
            // which would send whoever is verifying it hunting a parser bug that does not exist.
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try attestation.write(to: dir.appendingPathComponent("attestation.bin"))
            try Data(keyID.utf8).write(to: dir.appendingPathComponent("attestation.keyid"))
            try clientData.write(to: dir.appendingPathComponent("attestation.clientdata"))
            NSLog("[attest-capture] wrote %d bytes, keyID=%@", attestation.count, keyID)
        } catch {
            NSLog("[attest-capture] failed: %@", String(describing: error))
        }
    }
}
#endif

import DeviceCheck
import Foundation

/// Apple App Attest, wrapped so the rest of the app deals in claims rather than in DeviceCheck.
///
/// Attest once per key, assert every time after. Apple throttles attestation and uses it to build a
/// per-device risk metric, so burning a fresh key on every claim would both fail and degrade the
/// signal the relay eventually depends on.
actor AttestClient {
    enum Failure: Error, Equatable {
        /// This device cannot attest. Not an error to retry — the app says so in the UI instead.
        case unsupported
        case service(String)
    }

    private let service = DCAppAttestService.shared
    private let keyIDDefaultsKey = "bambu.attestKeyID"

    /// Whether this device can attest at all.
    ///
    /// False in the Simulator, on Apple silicon Macs running iOS apps, in app extensions, and on a
    /// small fraction of genuine devices. Those installs must be *told* — a silent 403 loop is the
    /// failure this codebase keeps rediscovering, where a limitation is discovered by silence.
    nonisolated var isSupported: Bool { DCAppAttestService.shared.isSupported }

    private var cachedKeyID: String? {
        get { UserDefaults.standard.string(forKey: keyIDDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: keyIDDefaultsKey) }
    }

    /// Produces a proof over `clientData`: an attestation on first use of a key, an assertion after.
    func proof(for clientData: Data) async throws -> ClaimBuilder.AttestProof {
        guard isSupported else { throw Failure.unsupported }

        let hash = Data(SHA256Digest.of(clientData))

        if let keyID = cachedKeyID {
            do {
                let assertion = try await service.generateAssertion(keyID, clientDataHash: hash)
                return ClaimBuilder.AttestProof(
                    keyID: keyID, attestation: nil, assertion: assertion.base64URLEncodedString()
                )
            } catch {
                // The key is gone or Apple rejected it; the relay would answer reattest_required
                // anyway. Start over rather than looping on a key that can no longer assert.
                cachedKeyID = nil
            }
        }

        let keyID = try await service.generateKey()
        do {
            let attestation = try await service.attestKey(keyID, clientDataHash: hash)
            cachedKeyID = keyID
            return ClaimBuilder.AttestProof(
                keyID: keyID, attestation: attestation.base64URLEncodedString(), assertion: nil
            )
        } catch let error as NSError where error.code == DCError.serverUnavailable.rawValue {
            // Apple's guidance: retry attestation with the SAME key and client-data hash rather
            // than generating another. A fresh key per retry degrades the device's risk metric,
            // which is the signal the relay's fraud assessment eventually reads. The caller's retry
            // reuses this key because it is only cached on success — so hold it here.
            cachedKeyID = keyID
            throw Failure.service("attestation service unavailable; retry with the same key")
        } catch {
            throw Failure.service(String(describing: error))
        }
    }

    /// Discards the current key so the next claim attests afresh. The answer to the relay's
    /// `reattest_required`, which means it holds no public key for us — a restore that predates
    /// this install, not an attack.
    func reattest() {
        cachedKeyID = nil
    }
}

/// Small shim so the wrapper does not depend on CryptoKit's type surface at its boundary.
private enum SHA256Digest {
    static func of(_ data: Data) -> [UInt8] {
        var hasher = Hasher256()
        hasher.update(data)
        return hasher.finalize()
    }
}

import CryptoKit

private struct Hasher256 {
    private var sha = SHA256()
    mutating func update(_ data: Data) { sha.update(data: data) }
    mutating func finalize() -> [UInt8] { Array(sha.finalize()) }
}

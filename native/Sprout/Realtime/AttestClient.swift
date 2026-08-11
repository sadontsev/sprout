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

    /// Whether a key has already been attested, so the caller can request a challenge for the right
    /// purpose. The relay checks that the purpose matches the proof: an attestation challenge lives
    /// fifteen minutes to honour Apple's retry guidance and an assertion challenge two, and letting
    /// one satisfy the other would stretch the assertion replay window sevenfold.
    nonisolated var hasAttestedKey: Bool {
        UserDefaults.standard.string(forKey: "bambu.attestKeyID") != nil
    }

    private var cachedKeyID: String? {
        get { UserDefaults.standard.string(forKey: keyIDDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: keyIDDefaultsKey) }
    }

    /// Which proof the next claim will carry.
    ///
    /// Decided and *held* in one actor-isolated step, because the challenge must be requested for
    /// the matching purpose and the relay checks that they agree. Deciding separately loses a race
    /// that happens routinely: two registrations build claims at once, one confirms the attest key
    /// mid-flight, and the other has already asked for an attestation challenge it will now answer
    /// with an assertion. The relay rejects that as challenge_invalid — correctly.
    enum Plan: String {
        case attestation
        case assertion
    }

    private var heldPlan: Plan?

    /// Reserves the proof kind for the claim about to be built.
    func planProof() -> Plan {
        let plan: Plan = cachedKeyID == nil ? .attestation : .assertion
        heldPlan = plan
        return plan
    }

    /// Serialises DeviceCheck work. See SerialGate for why `actor` alone is not enough.
    private let gate = SerialGate()

    /// Produces a proof over `clientData`, honouring the reserved plan.
    ///
    /// Serialised against every other in-flight proof: two claims built in the same instant — a
    /// print card and a drying card registering together, which is routine — otherwise both sit
    /// inside `generateAssertion` and Apple fails one.
    func proof(for clientData: Data) async throws -> ClaimBuilder.AttestProof {
        try await gate.run { [self] in try await makeProof(for: clientData) }
    }

    private func makeProof(for clientData: Data) async throws -> ClaimBuilder.AttestProof {
        guard isSupported else { throw Failure.unsupported }
        let plan = heldPlan ?? planProof()
        heldPlan = nil
        let hash = Data(SHA256Digest.of(clientData))

        if plan == .assertion {
            guard let keyID = cachedKeyID else {
                // Planned an assertion but the key vanished under us. Fail rather than silently
                // attesting: the challenge in flight is an assertion challenge and the relay would
                // reject the mismatch anyway, less informatively.
                throw Failure.service("planned an assertion but no key is cached")
            }
            do {
                let assertion = try await service.generateAssertion(keyID, clientDataHash: hash)
                return ClaimBuilder.AttestProof(
                    keyID: keyID, attestation: nil, assertion: assertion.base64URLEncodedString()
                )
            } catch {
                // THE RECOVERY THAT WAS UNREACHABLE. A do/catch further down handled this, but it
                // sat below an early `throw` on the assertion plan, so once any key was cached —
                // i.e. always, after the first success — it could never run.
                //
                // The case that matters: the phone is restored from a backup or a device-to-device
                // transfer. UserDefaults comes back and so does the cached key id; the Secure
                // Enclave key does not. Every assertion then throws DCError.invalidKey, buildClaim
                // logs and returns nil, the registration goes out unclaimed, and — with nothing
                // clearing the key — the install can never produce a valid proof again. It was
                // permanent, and silent apart from one NSLog.
                cachedKeyID = nil
                unattestedKeyID = nil
                throw Failure.service("assertion failed; discarded the key so the next claim attests: "
                                      + String(describing: error))
            }
        }

        // Reuse a key that was generated but never accepted, rather than minting another. Apple's
        // guidance is to retry attestation with the SAME key, and a fresh key per retry degrades
        // the device's risk metric — the signal the relay's fraud assessment reads.
        // Written out rather than with `??`: the right-hand side is async, and an autoclosure
        // cannot carry an await.
        let keyID: String
        if let held = unattestedKeyID {
            keyID = held
        } else {
            keyID = try await service.generateKey()
        }
        unattestedKeyID = keyID
        do {
            let attestation = try await service.attestKey(keyID, clientDataHash: hash)
            // Deliberately NOT cached here. Apple accepting the attestation says nothing about
            // whether the relay recorded it, and caching on Apple's word alone produces a loop the
            // app cannot escape: it asserts with a key the relay has never seen, is told to
            // re-attest, attests, caches optimistically again, and asserts again. The key is
            // confirmed only once a registration carrying it is accepted.
            pendingKeyID = keyID
            return ClaimBuilder.AttestProof(
                keyID: keyID, attestation: attestation.base64URLEncodedString(), assertion: nil
            )
        } catch let error as NSError where error.code == DCError.serverUnavailable.rawValue {
            // Transient. The key is held in `unattestedKeyID` — NOT in `cachedKeyID`, which was the
            // bug: writing it there made planProof() see a cached key and plan an ASSERTION on the
            // next attempt, for a key Apple had never attested. DeviceCheck rejects that with
            // invalidKey, and with the assertion path having had no catch, nothing ever cleared it.
            // One transient Apple outage during the very first claim left the install permanently
            // unable to produce any proof.
            throw Failure.service("attestation service unavailable; retry with the same key")
        } catch {
            throw Failure.service(String(describing: error))
        }
    }

    /// A key generated but not yet attested-and-accepted. Distinct from `cachedKeyID`, which means
    /// "the relay holds the public half and assertions will verify" — the two look alike and answer
    /// different questions, and conflating them is what made a transient failure permanent.
    private var unattestedKeyID: String?

    /// A key that has attested with Apple but has not yet been accepted by the relay.
    private var pendingKeyID: String?

    /// Promote the pending key: the relay accepted a registration carrying its attestation, so it
    /// now holds the public half and later assertions will verify.
    func confirmAttested() {
        if let pendingKeyID {
            cachedKeyID = pendingKeyID
            self.pendingKeyID = nil
            unattestedKeyID = nil
        }
    }

    /// Discards the current key so the next claim attests afresh. The answer to the relay's
    /// `reattest_required`, which means it holds no public key for us — a restore that predates
    /// this install, not an attack.
    func reattest() {
        cachedKeyID = nil
        pendingKeyID = nil
        unattestedKeyID = nil
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

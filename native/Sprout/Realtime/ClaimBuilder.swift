import Foundation

/// Assembles the claim a registration carries when Trellis is relaying to Canopy.
///
/// Kept separate from the networking so the assembly — which is where a mistake fails every claim —
/// is testable without a device, an attestation service, or a server. The two proofs arrive as
/// injected closures for the same reason.
struct ClaimBuilder: Sendable {
    /// What Canopy's `binding_kind` calls a token. Not Trellis's `kind`, which is `print`/`dry`:
    /// both travel in the same request body and mean different things, so they never share a name.
    enum BindingKind: String {
        case activity
        case start
        case device
    }

    /// Produces an App Attest proof over the client-data hash. Returns the key id and either an
    /// attestation (first use of a key) or an assertion (every later claim).
    typealias AttestProvider = @Sendable (_ clientData: Data) async throws -> AttestProof

    struct AttestProof: Equatable, Sendable {
        var keyID: String
        /// Exactly one of these is set. Canopy refuses a claim carrying both or neither, because
        /// "which proof am I checking" has no sensible default.
        var attestation: String?
        var assertion: String?
    }

    /// The body posted alongside a registration.
    struct Claim: Encodable, Equatable, Sendable {
        let token: String
        let clientData: String
        let challenge: String
        let pairingPublicKey: String
        let pairingSignature: String
        let deviceId: String
        let bindingKind: String
        let apnsEnvironment: String
        let attestKeyId: String
        let vouchNonce: String?
        let attestation: String?
        let assertion: String?
    }

    var identity: PairingIdentity
    var environment: APNSEnvironment
    /// Signs the client data with the pairing key.
    var sign: @Sendable (Data) throws -> String
    var attest: AttestProvider

    /// Builds a claim for one token.
    ///
    /// The client data is encoded once and both proofs are made over those exact bytes, which are
    /// then transmitted verbatim. Nothing re-encodes: Canopy hashes what it receives and checks the
    /// fields parsed out of it, so a second encoding pass is the one thing that could make a
    /// genuine claim fail verification.
    func build(
        token: String,
        kind: BindingKind,
        challenge: String,
        vouchNonce: String? = nil
    ) async throws -> Claim {
        let data = ClaimData(
            challenge: challenge,
            token: token,
            pairingPublicKey: identity.publicKey,
            deviceID: identity.deviceID,
            bindingKind: kind.rawValue,
            apnsEnvironment: environment.rawValue,
            vouchNonce: vouchNonce
        )

        let bytes = try data.encoded()
        let proof = try await attest(bytes)

        return Claim(
            token: token,
            clientData: bytes.base64URLEncodedString(),
            challenge: challenge,
            pairingPublicKey: identity.publicKey,
            pairingSignature: try sign(bytes),
            deviceId: identity.deviceID,
            bindingKind: kind.rawValue,
            apnsEnvironment: environment.rawValue,
            attestKeyId: proof.keyID,
            vouchNonce: (vouchNonce?.isEmpty ?? true) ? nil : vouchNonce,
            attestation: proof.attestation,
            assertion: proof.assertion
        )
    }
}

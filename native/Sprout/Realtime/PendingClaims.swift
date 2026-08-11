import Foundation

/// Tokens this device still owes the server a registration for.
///
/// All three registrations go through here, which they did not before: only `/register` ever
/// retried. `/register-start` was a fire-and-forget POST inside the push-to-start token stream
/// whose result was discarded and which only iterates again when the token rotates, and
/// `/register-device` did not exist at all. So a brand-new install whose first attempt met a down
/// server never registered a start token for the rest of the process lifetime — the worst state
/// there is, because the server then has nothing to push a start *to* and the lock screen stays
/// empty for the whole print.
///
/// What is queued is an **intent**, never a signed claim. A claim consumes a single-use challenge
/// and advances the Secure Enclave counter, so it cannot be replayed: every retry has to acquire a
/// fresh challenge and produce fresh proofs.
struct PendingClaims: Equatable {
    struct Intent: Equatable, Codable {
        var token: String
        var kind: String
        /// Set when the server has told us this token needs re-claiming.
        var vouchNonce: String?
    }

    private(set) var intents: [Intent] = []

    /// Records that `token` needs registering. Idempotent by token: a stream that re-emits the same
    /// token must not queue it twice.
    mutating func add(token: String, kind: ClaimBuilder.BindingKind, vouchNonce: String? = nil) {
        guard !token.isEmpty else { return }
        if let index = intents.firstIndex(where: { $0.token == token }) {
            // A nonce arriving for a token already queued is new information; keep it.
            if let vouchNonce, !vouchNonce.isEmpty {
                intents[index].vouchNonce = vouchNonce
            }
            intents[index].kind = kind.rawValue
            return
        }
        intents.append(Intent(token: token, kind: kind.rawValue, vouchNonce: vouchNonce))
    }

    /// Attaches a vouch nonce that arrived by silent push.
    mutating func attach(nonce: String, to token: String) {
        guard let index = intents.firstIndex(where: { $0.token == token }) else { return }
        intents[index].vouchNonce = nonce
    }

    mutating func remove(token: String) {
        intents.removeAll { $0.token == token }
    }

    /// Tokens the server says need re-claiming, intersected against what this device actually holds.
    ///
    /// The intersection is the security property, not a tidiness one. Read the other way — as a list
    /// of tokens to go and claim — it would be an attestation oracle: a compromised server could
    /// name another user's token and have this device produce a valid, signed claim for it, which is
    /// precisely the cross-user harm the whole design exists to prevent.
    func needingReclaim(serverSays tokens: [String], heldTokens: Set<String>) -> [String] {
        tokens.filter { heldTokens.contains($0) }
    }

    var isEmpty: Bool { intents.isEmpty }

    // MARK: - persistence

    func encoded() -> Data? { try? JSONEncoder().encode(intents) }

    static func decoded(_ data: Data?) -> PendingClaims {
        guard let data, let intents = try? JSONDecoder().decode([Intent].self, from: data) else {
            return PendingClaims()
        }
        var out = PendingClaims()
        out.intents = intents
        return out
    }
}

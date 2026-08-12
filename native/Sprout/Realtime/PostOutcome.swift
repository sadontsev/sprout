import Foundation

/// What a POST to Trellis actually did.
///
/// Four outcomes, deliberately kept apart, because each is fixed somewhere different: in the
/// phone's Settings, on the network, or in the server. The type this replaced —
/// `(ok: Bool, bound: Bool, reason: String?)` — answered "did it work?" and threw away "why not",
/// returning `(false, false, nil)` for a missing URL, an unreachable host and a server fault alike.
///
/// That cost a whole print. Trellis's API-key gate raised an exception, so every authenticated
/// endpoint answered HTTP 500; the phone registered a card, received the 500, wrote nothing to the
/// log, and left the Live Activity frozen at its opening content while every visible component
/// looked healthy. The only NSLog on the failure path covered "stored but not bound" — the one
/// case that was not happening.
///
/// This is the same shape as the bug CLAUDE.md names as this codebase's recurring one: a value that
/// answers a NEARBY question. "It failed" and "the server refused it" are not synonyms, and neither
/// are "the server refused it" and "your key is wrong".
enum PostOutcome: Equatable, Sendable {
    /// The server accepted and stored it. `bound` reports whether the relay can actually push to
    /// the token — a registration Trellis stored but could not bind is the normal outcome of an App
    /// Attest hiccup, and treating it as finished is what leaves a card frozen.
    case stored(bound: Bool)
    /// Nothing was sent: no Trellis URL is configured, or the body would not encode.
    case misconfigured
    /// Nothing arrived: offline, DNS, TLS, or a timeout.
    case unreachable
    /// The server answered, and said no.
    case refused(status: Int, detail: String?)

    /// True only when the server stored it. Kept so the call sites read as before.
    var ok: Bool {
        if case .stored = self { return true }
        return false
    }

    /// Never true for a failure: a registration is finalised on `ok && bound`, so a failure that
    /// looked bound would be marked done and never retried.
    var bound: Bool {
        if case .stored(let bound) = self { return bound }
        return false
    }

    /// The server's own `detail`, and only that. `handle(refusal:)` acts on this string — a detail
    /// invented for a transport failure would trigger attestation recovery on a phone that is
    /// merely offline.
    var reason: String? {
        if case .refused(_, let detail) = self { return detail }
        return nil
    }

    /// The line to write to the device log, or nil when there is nothing worth saying.
    ///
    /// Pure, so the wording is testable — the wording is the whole point of the type. This runs on a
    /// 4-second tick, so success must be silent, and each failure must be distinguishable from the
    /// others by someone reading the log with no other context.
    static func logLine(path: String, token: String?, outcome: PostOutcome) -> String? {
        // The prefix, never the whole token: enough to tell two cards apart in a log, not enough to
        // be a push credential lying around in one.
        let who = token.map { " \($0.prefix(8))" } ?? ""

        switch outcome {
        case .stored(bound: true):
            return nil
        case .stored(bound: false):
            return "[push] \(path)\(who): stored but NOT bound — the relay cannot push to this token "
                + "yet, so the card would stay frozen. Will retry."
        case .misconfigured:
            return "[push] \(path)\(who): not sent — no push server URL is configured. "
                + "Set it in Settings; nothing will be registered until then."
        case .unreachable:
            return "[push] \(path)\(who): could not reach Trellis (offline, DNS, TLS or timeout). "
                + "Nothing was sent."
        case .refused(let status, let detail):
            let said = detail.map { " — \($0)" } ?? ""
            return "[push] \(path)\(who): refused with HTTP \(status)\(said).\(advice(for: status))"
        }
    }

    /// Where to look, per status. Getting this wrong is expensive in the other direction: blaming a
    /// 500 on the API key sends someone to re-check a credential that was never consulted.
    private static func advice(for status: Int) -> String {
        switch status {
        case 401, 403:
            return " The API key this app sends is not one your Bambuddy accepts — check Settings."
        case 404:
            return " Check the push server URL in Settings points at Trellis."
        case 500...599:
            return " That is a fault in Trellis itself, not in this app or your settings —"
                + " check its container log."
        default:
            return ""
        }
    }
}

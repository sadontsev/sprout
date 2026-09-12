import Foundation

/// Builds a claim and DELIVERS it as one unit, one claim at a time.
///
/// **Why generation alone is not enough.** An App Attest assertion carries a counter that the
/// Secure Enclave increments on every signature, and the relay accepts an assertion only if its
/// counter is greater than the last one it stored for that key — Apple's rule, verbatim: "Verify
/// that the authenticator data's counter value is greater than the value from the previous
/// assertion". Canopy implements exactly that (`counter <= storedCounter` → reject), and it must.
///
/// `AttestClient` already serialises `generateAssertion`, so assertions were always SIGNED in
/// order. They were not SENT in order: each claim's POST ran after the gate released, and three
/// registrations firing together — the card, the push-to-start token and the device token, which is
/// the ordinary case at the start of every print — raced over the network. Whichever carried the
/// higher counter could reach the relay first, and the lower one was then refused.
///
/// Measured on the live service, 2026-09-12: three `/challenge` requests at 13:54:31, then
/// `appattest: counter is not acceptable` for the print card's token. Trellis never bound it, the
/// app was backgrounded and so never retried, and all fifty updates for that print were refused as
/// `not_bound` — the card sat on "Homing toolhead, 0 %" until the print finished. The same
/// rejection appears in the relay's log on nearly every day since 19 August, landing on whichever
/// of the three requests happened to lose.
///
/// So the unit of serialisation is challenge → proof → POST. A later claim cannot even fetch its
/// challenge until the earlier one's POST has returned, which means no counter can overtake another.
final class ClaimSequencer: Sendable {
    private let gate = SerialGate()

    /// Runs `build`, hands its result to `send`, and returns what `send` said — with nothing from
    /// any other submission allowed to start in between.
    func submit<Claim: Sendable, Outcome: Sendable>(
        build: @escaping @Sendable () async -> Claim,
        send: @escaping @Sendable (Claim) async -> Outcome
    ) async -> Outcome {
        await gate.run { await send(await build()) }
    }
}

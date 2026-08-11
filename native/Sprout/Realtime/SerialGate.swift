import Foundation

/// Runs async work strictly one at a time.
///
/// This exists because `actor` does not do it. An actor guarantees exclusive access to its *state*,
/// not exclusive execution across a suspension: an actor method that awaits is **reentrant**, so two
/// callers can both be inside it, suspended at the same `await`. For state that is only touched
/// before and after the await, that is exactly what you want. For a resource that will not tolerate
/// two callers at once, it is silent breakage.
///
/// App Attest is such a resource. A print card and a drying card register in the same instant —
/// the normal case, not an edge one — and if both are inside `generateAssertion` together Apple
/// fails one. Live, that looked like flakiness: of two simultaneous registrations exactly one came
/// back `bound=true`, alternating which one. It was a queueing bug.
actor SerialGate {
    /// The tail of the chain. Each caller awaits the previous one before starting.
    private var tail: Task<Void, Never>?

    /// Runs `work` after every call already queued ahead of it.
    ///
    /// The chain is extended whether or not `work` succeeds. A failure that did not extend it would
    /// release the next caller while the resource is still busy — the very overlap being prevented,
    /// reappearing only on the error path, where it is hardest to notice.
    func run<T: Sendable>(_ work: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

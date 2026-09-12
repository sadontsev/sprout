import XCTest
@testable import Sprout

/// Stands in for the Secure Enclave: every signature takes the next counter value.
private actor FakeEnclave {
    private var counter = 0

    func sign() -> Int {
        counter += 1
        return counter
    }
}

/// Stands in for Canopy's assertion check, which is Apple's rule: a counter is accepted only if it
/// is greater than the last one stored. See `canopy/internal/appattest/appattest.go`,
/// `if counter <= storedCounter { return 0, ErrCounter }`.
private actor FakeRelay {
    private var stored = 0
    private(set) var accepted: [Int] = []
    private(set) var rejected: [Int] = []

    func verify(_ counter: Int) -> Bool {
        guard counter > stored else {
            rejected.append(counter)
            return false
        }
        stored = counter
        accepted.append(counter)
        return true
    }
}

/// An ordered record of what ran, so interleaving is visible rather than inferred.
private actor EventLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

/// How long a claim's POST takes, chosen so a LATER claim arrives FIRST when nothing holds them in
/// order. Keyed on the counter, not the caller index, because the caller order is up to the task
/// scheduler while the counter order is exactly the order the enclave signed in.
private func transit(for counter: Int, of total: Int) -> UInt64 {
    UInt64(total - counter + 1) * 8_000_000
}

final class ClaimSequencerTests: XCTestCase {

    private let claims = 5

    /// The property the type exists for: nothing from one submission starts between another's
    /// build and its send.
    func testABuildNeverStartsBeforeThePreviousSendHasFinished() async {
        let sequencer = ClaimSequencer()
        let log = EventLog()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<claims {
                group.addTask {
                    _ = await sequencer.submit(
                        build: { () -> Int in
                            await log.record("build \(i)")
                            try? await Task.sleep(nanoseconds: 2_000_000)
                            return i
                        },
                        send: { (built: Int) -> Int in
                            try? await Task.sleep(nanoseconds: 4_000_000)
                            await log.record("send \(built)")
                            return built
                        }
                    )
                }
            }
        }

        let events = await log.events
        XCTAssertEqual(events.count, claims * 2)
        for pair in stride(from: 0, to: events.count, by: 2) {
            let build = events[pair]
            let send = events[pair + 1]
            XCTAssertTrue(build.hasPrefix("build "), "expected a build at \(pair), got \(build)")
            XCTAssertEqual(
                build.dropFirst("build ".count), send.dropFirst("send ".count),
                "a build must be followed by ITS OWN send, never by another claim's build: \(events)")
        }
    }

    /// The reported failure, end to end: counters signed in order must reach the relay in order,
    /// even when the later POSTs are faster.
    func testEveryCounterIsAcceptedWhenBuildAndSendAreOneUnit() async {
        let sequencer = ClaimSequencer()
        let enclave = FakeEnclave()
        let relay = FakeRelay()
        let total = claims

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    _ = await sequencer.submit(
                        build: { await enclave.sign() },
                        send: { (counter: Int) -> Bool in
                            try? await Task.sleep(nanoseconds: transit(for: counter, of: total))
                            return await relay.verify(counter)
                        }
                    )
                }
            }
        }

        let rejected = await relay.rejected
        let accepted = await relay.accepted
        XCTAssertEqual(rejected, [], "no claim may be refused for arriving out of order")
        XCTAssertEqual(accepted, Array(1...total))
    }

    /// The control, and the shape that shipped: signing serialised, sending not. Without this the
    /// test above would pass just as well against a sequencer that did nothing, if the POSTs
    /// happened never to overtake each other.
    func testSerialisingOnlyTheSignatureStillLetsCountersArriveOutOfOrder() async {
        let signing = SerialGate()
        let enclave = FakeEnclave()
        let relay = FakeRelay()
        let total = claims

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    let counter = await signing.run { await enclave.sign() }
                    try? await Task.sleep(nanoseconds: transit(for: counter, of: total))
                    _ = await relay.verify(counter)
                }
            }
        }

        let rejected = await relay.rejected
        XCTAssertFalse(
            rejected.isEmpty,
            "with only the signature gated, a later counter overtakes an earlier one — the bug")
    }

    /// Outcomes must not be crossed between callers: each registration acts on its own answer.
    func testEachCallerReceivesItsOwnOutcome() async {
        let sequencer = ClaimSequencer()

        async let slow = sequencer.submit(
            build: { () -> String in
                try? await Task.sleep(nanoseconds: 6_000_000)
                return "slow"
            },
            send: { (built: String) -> String in "sent \(built)" }
        )
        async let fast = sequencer.submit(
            build: { () -> String in "fast" },
            send: { (built: String) -> String in "sent \(built)" }
        )

        let results = await [slow, fast]
        XCTAssertEqual(results, ["sent slow", "sent fast"])
    }
}

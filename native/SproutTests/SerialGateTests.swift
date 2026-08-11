import XCTest
@testable import Sprout

/// Counts how many callers are inside the guarded section at once.
private actor OverlapTracker {
    private(set) var peak = 0
    private(set) var completed = 0
    private var current = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
        completed += 1
    }
}

/// Work that suspends in the middle — the only kind where reentrancy is observable.
///
/// Free-standing rather than a method: capturing a non-Sendable XCTestCase in a task group is a
/// Swift 6 error, and threading `self` through would be noise unrelated to what is being tested.
private func overlapping(_ tracker: OverlapTracker) -> @Sendable () async throws -> Void {
    {
        await tracker.enter()
        try? await Task.sleep(nanoseconds: 2_000_000)
        await tracker.leave()
    }
}

final class SerialGateTests: XCTestCase {
    func testOnlyOneCallerRunsAtATime() async {
        // The property the whole type exists for. An `actor` alone does NOT give this: an actor
        // method that awaits is reentrant, which is why App Attest failed one of every two
        // simultaneous claims while sitting behind one.
        let gate = SerialGate()
        let tracker = OverlapTracker()
        let work = overlapping(tracker)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await gate.run(work) }
            }
        }

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "two callers inside at once is exactly what Apple rejects")
    }

    func testWithoutTheGateTheSameWorkDoesOverlap() async {
        // The control. Without it, the test above would pass just as well against a gate that did
        // nothing, if the work happened never to interleave.
        let tracker = OverlapTracker()
        let work = overlapping(tracker)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await work() }
            }
        }

        let peak = await tracker.peak
        XCTAssertGreaterThan(peak, 1, "the work must genuinely overlap when left ungated")
    }

    func testEveryCallerStillRuns() async {
        let gate = SerialGate()
        let tracker = OverlapTracker()
        let work = overlapping(tracker)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await gate.run(work) }
            }
        }

        let done = await tracker.completed
        XCTAssertEqual(done, 8, "serialising must not drop work")
    }

    func testAValueIsReturnedToItsOwnCaller() async throws {
        let gate = SerialGate()

        async let a = gate.run { () -> Int in
            try? await Task.sleep(nanoseconds: 2_000_000)
            return 1
        }
        async let b = gate.run { () -> Int in 2 }

        let results = try await [a, b]
        XCTAssertEqual(results, [1, 2], "results must not be crossed between callers")
    }

    func testAThrownErrorReachesItsOwnCaller() async {
        struct Boom: Error {}
        let gate = SerialGate()

        do {
            _ = try await gate.run { throw Boom() }
            XCTFail("the error must propagate")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testAFailureDoesNotBreakTheChain() async {
        // The error path is where this would silently regress: a failure that did not extend the
        // chain releases the next caller while the resource is still busy, reintroducing the exact
        // overlap being prevented — and only when something has already gone wrong.
        struct Boom: Error {}
        let gate = SerialGate()
        let tracker = OverlapTracker()
        let work = overlapping(tracker)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    if i % 2 == 0 {
                        _ = try? await gate.run { throw Boom() }
                    } else {
                        try? await gate.run(work)
                    }
                }
            }
        }

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "interleaved failures must not release the gate early")
    }
}

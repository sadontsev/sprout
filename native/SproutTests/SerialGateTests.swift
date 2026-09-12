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

        // Typed as THROWING on purpose. This test predates the non-throwing overload, and once that
        // existed a closure with no `throw` in it resolved to the new overload silently — leaving the
        // throwing one without this test and the `try` below with nothing to try. The non-throwing
        // path has its own value-per-caller test in ClaimSequencerTests.
        async let a = gate.run { () async throws -> Int in
            try? await Task.sleep(nanoseconds: 2_000_000)
            return 1
        }
        async let b = gate.run { () async throws -> Int in 2 }

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

    /// The non-throwing overload is the same chain, not a second, weaker one — `ClaimSequencer` runs
    /// on it, and an overlap there reintroduces the App Attest counter race.
    func testTheNonThrowingOverloadAlsoRunsOneAtATime() async {
        let gate = SerialGate()
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.run { () async -> Void in
                        await tracker.enter()
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        await tracker.leave()
                    }
                }
            }
        }

        let peak = await tracker.peak
        let done = await tracker.completed
        XCTAssertEqual(peak, 1, "the non-throwing path must serialise exactly as the throwing one does")
        XCTAssertEqual(done, 8)
    }

    /// Both overloads share ONE chain: a throwing caller queued behind a non-throwing one must wait
    /// for it, or two kinds of work could still overlap on the same resource.
    func testBothOverloadsQueueBehindEachOther() async {
        struct Boom: Error {}
        let gate = SerialGate()
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    if i % 2 == 0 {
                        await gate.run { () async -> Void in
                            await tracker.enter()
                            try? await Task.sleep(nanoseconds: 2_000_000)
                            await tracker.leave()
                        }
                    } else {
                        _ = try? await gate.run { () async throws -> Void in
                            await tracker.enter()
                            try? await Task.sleep(nanoseconds: 2_000_000)
                            await tracker.leave()
                            throw Boom()
                        }
                    }
                }
            }
        }

        let peak = await tracker.peak
        XCTAssertEqual(peak, 1, "mixing the overloads must not open a gap in the chain")
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

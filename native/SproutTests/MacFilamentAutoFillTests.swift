#if os(macOS)
import XCTest
@testable import Sprout

/// Auto-filling the tray for a plate's filament, and the sequencing bug that stopped it working.
///
/// The matching itself was always right. What was wrong was WHEN it ran: `applyAutoFill` latched after
/// one attempt, and the only thing that re-ran it was `.onChange(of: usedSlots)` — a value that returns
/// `[1]` both when requirements are unasked and when the plate genuinely uses slot 1. For the
/// overwhelmingly common single-filament print the change never fired, so auto-fill decided against an
/// unanswered question, matched nothing, and never looked again. Every such print asked the user to pick
/// a tray by hand even when exactly one spool matched.
///
/// It looked intermittent because it is a race: whether `filament-requirements` returns before or after
/// the inventory decides whether auto-fill ever sees a requirement.
final class MacFilamentAutoFillTests: XCTestCase {

    // MARK: Fixtures — the demo AMS, which is a real H2C layout

    private func spool(_ global: Int, _ material: String, _ hex: String) -> LoadedFilament {
        LoadedFilament(slot: global, unitLabel: "AMS 1", localId: global,
                       material: material, colorHex: hex, colorName: nil, isSupport: false)
    }

    /// Purple PLA, black PETG, orange PLA — two PLAs, so material alone is ambiguous and the colour is
    /// what makes the answer unique.
    private var loaded: [LoadedFilament] {
        [spool(0, "PLA", "8E7CC3"), spool(1, "PETG", "1A1A1A"), spool(2, "PLA", "C1440E")]
    }

    private func want(_ type: String?, _ color: String?) -> FilamentRequirements.Requirement {
        FilamentRequirements.Requirement(slotId: 1, type: type, color: color, usedInPlate: true)
    }

    // MARK: The matching was never the problem

    /// One PLA of that exact colour, so the answer is unambiguous and auto-fill takes it.
    func testAnUnambiguousColourMatchBinds() {
        var trays: [Int: Int] = [:]
        MacFilamentMatching.autoFill(usedSlots: [1], requirement: { _ in want("PLA", "#8E7CC3") },
                                     loaded: loaded, activeTray: nil, into: &trays)
        XCTAssertEqual(trays[1], 0, "the purple PLA tray, by global id")
    }

    /// Material alone is ambiguous here — two PLAs — and a nearest-colour guess is the "brown spool
    /// labelled Orange" bug. Nothing is bound.
    func testAnAmbiguousMatchBindsNothing() {
        var trays: [Int: Int] = [:]
        MacFilamentMatching.autoFill(usedSlots: [1], requirement: { _ in want("PLA", nil) },
                                     loaded: loaded, activeTray: nil, into: &trays)
        XCTAssertTrue(trays.isEmpty, "unsure must stay blank and let the row say what is missing")
    }

    /// **The heart of it.** With no requirement to match, auto-fill binds nothing — so running it before
    /// the answer arrives achieves nothing AND, in the view, latched so it never ran again.
    func testWithNoRequirementYetNothingCanBind() {
        var trays: [Int: Int] = [:]
        MacFilamentMatching.autoFill(usedSlots: [1], requirement: { _ in nil },
                                     loaded: loaded, activeTray: nil, into: &trays)
        XCTAssertTrue(trays.isEmpty)
    }

    /// Running it again once the answer HAS arrived does bind — which is why the fix is to re-run rather
    /// than to change the matcher.
    func testTheSameCallBindsOnceTheAnswerArrives() {
        var trays: [Int: Int] = [:]
        MacFilamentMatching.autoFill(usedSlots: [1], requirement: { _ in nil },
                                     loaded: loaded, activeTray: nil, into: &trays)
        XCTAssertTrue(trays.isEmpty, "before")
        MacFilamentMatching.autoFill(usedSlots: [1], requirement: { _ in want("PLA", "#8E7CC3") },
                                     loaded: loaded, activeTray: nil, into: &trays)
        XCTAssertEqual(trays[1], 0, "after")
    }

    // MARK: The key that makes the re-run possible

    /// The three states `FilamentRequirements?` collapses into two, and only the first means WAIT.
    func testUnaskedIsDistinctFromAskedAndEmpty() {
        XCTAssertEqual(MacFilamentMatching.requirementKey(nil, asked: false), "unasked")
        XCTAssertEqual(MacFilamentMatching.requirementKey(nil, asked: true), "asked-empty")
        XCTAssertNotEqual(MacFilamentMatching.requirementKey(nil, asked: false),
                          MacFilamentMatching.requirementKey(nil, asked: true),
                          "a failed fetch must be distinguishable from silence, or auto-fill waits for ever")
    }

    /// The regression that matters: the key MUST change when a single-slot answer arrives. `usedSlots`
    /// does not — it is `[1]` before and `[1]` after — which is exactly why auto-fill never re-ran.
    func testTheKeyChangesWhenASingleSlotAnswerArrives() {
        let before = MacFilamentMatching.requirementKey(nil, asked: false)
        let after = MacFilamentMatching.requirementKey(
            FilamentRequirements(filaments: [want("PLA", "#8E7CC3")]), asked: true
        )
        XCTAssertNotEqual(before, after,
                          "the single-filament case is the common one and the one that was broken")
    }

    /// And it changes when the MATERIAL changes even though the slot list does not — a different plate
    /// of the same shape is a different question.
    func testTheKeyChangesWhenOnlyTheMaterialChanges() {
        let pla = MacFilamentMatching.requirementKey(
            FilamentRequirements(filaments: [want("PLA", "#8E7CC3")]), asked: true)
        let petg = MacFilamentMatching.requirementKey(
            FilamentRequirements(filaments: [want("PETG", "#8E7CC3")]), asked: true)
        XCTAssertNotEqual(pla, petg)
    }

    /// Stable across reordering, so a server that returns the same slots in another order does not
    /// re-trigger a pointless re-fill.
    func testTheKeyIsOrderIndependent() {
        let a = MacFilamentMatching.requirementKey(FilamentRequirements(filaments: [
            FilamentRequirements.Requirement(slotId: 1, type: "PLA", color: "#111111"),
            FilamentRequirements.Requirement(slotId: 2, type: "PETG", color: "#222222"),
        ]), asked: true)
        let b = MacFilamentMatching.requirementKey(FilamentRequirements(filaments: [
            FilamentRequirements.Requirement(slotId: 2, type: "PETG", color: "#222222"),
            FilamentRequirements.Requirement(slotId: 1, type: "PLA", color: "#111111"),
        ]), asked: true)
        XCTAssertEqual(a, b)
    }
}
#endif

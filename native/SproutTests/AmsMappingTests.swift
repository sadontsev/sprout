import XCTest
@testable import Sprout

/// Covers `Domain/AmsMapping.swift` — the array that decides which spool a print pulls from.
///
/// The shapes here are measured, not invented: the owner's H2C exposes global tray ids `0…3`
/// (AMS 0), `4…7` (AMS 1), `128` (AMS-HT) and `254`/`255` (external), and a real MakerWorld plate
/// was observed needing slots `[1, 2, 3]` (a 3-colour Benchy) and, on other plates of the same file,
/// exactly one slot that was **not** slot 1.
final class AmsMappingTests: XCTestCase {

    // MARK: - The single-filament path must not move

    /// The overwhelmingly common case, and the one that already worked. `[tray]` — one element.
    func testASingleSlotOnePrintProducesTheOneElementArrayThatShippedBefore() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [1], trays: [1: 0]), [0])
        XCTAssertEqual(AmsMapping.build(usedSlots: [1], trays: [1: 7]), [7])
    }

    /// Measured: plate 2 of the seed tray uses slot 2, plate 4 uses slot 3. A one-element array would
    /// address slot 1 — a filament those plates never ask for — and leave the real one unmapped.
    func testASoleSlotThatIsNotSlotOneIsPaddedSoTheTrayLandsAtTheRightIndex() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [2], trays: [2: 5]), [-1, 5])
        XCTAssertEqual(AmsMapping.build(usedSlots: [3], trays: [3: 128]), [-1, -1, 128])
    }

    // MARK: - Multi-filament

    /// The 3-colour Benchy: plate 1 needs slots 1, 2 and 3, mapped across two AMS units.
    func testEverySlotGetsItsOwnTrayInSlotOrder() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [1, 2, 3], trays: [1: 0, 2: 5, 3: 128]),
                       [0, 5, 128])
    }

    /// Index is the SLOT, value is the TRAY. Swapping them is the failure the wizard's comment warns
    /// about, and it is silent — both are small integers.
    func testIndexIsTheSlotAndValueIsTheTray() {
        let mapping = AmsMapping.build(usedSlots: [1, 2], trays: [1: 4, 2: 1])
        XCTAssertEqual(mapping, [4, 1])
        XCTAssertNotEqual(mapping, [1, 4], "index/value swapped — this debits the wrong spool")
    }

    /// The plate's slots need not be contiguous or ordered.
    func testGapsBetweenUsedSlotsAreUnmappedNotCollapsed() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [3, 1], trays: [1: 2, 3: 6]), [2, -1, 6])
    }

    func testTheExternalSpoolIdsSurviveUntouched() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [1, 2], trays: [1: 254, 2: 255]), [254, 255])
    }

    // MARK: - Unmapped slots are never guessed

    /// A slot with no tray is sent as -1. Substituting some other tray would print a colour the user
    /// never chose, which is worse than the printer refusing.
    func testASlotWithNoTrayIsSentUnmappedRatherThanDefaulted() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [1, 2, 3], trays: [1: 0, 3: 6]), [0, -1, 6])
    }

    func testUnmappedNamesExactlyTheSlotsStillMissingInOrder() {
        XCTAssertEqual(AmsMapping.unmapped(usedSlots: [3, 1, 2], trays: [2: 5]), [1, 3])
        XCTAssertEqual(AmsMapping.unmapped(usedSlots: [1], trays: [1: 0]), [])
    }

    func testIsCompleteIsTheStartPreconditionNotACount() {
        XCTAssertTrue(AmsMapping.isComplete(usedSlots: [1, 2], trays: [1: 0, 2: 5]))
        XCTAssertFalse(AmsMapping.isComplete(usedSlots: [1, 2], trays: [1: 0]))
        // Trays for slots the plate does not use do not make it complete.
        XCTAssertFalse(AmsMapping.isComplete(usedSlots: [1, 2], trays: [1: 0, 3: 6]))
    }

    func testIsCompleteIsFalseWhenNothingIsRequired() {
        XCTAssertFalse(AmsMapping.isComplete(usedSlots: [], trays: [1: 0]),
                       "an empty requirement list is 'unknown', not 'satisfied'")
    }

    // MARK: - Equivalence with the shipped single-filament behaviour

    /// The three reachable paths of the private `amsMapping(tray:)` this replaced. Any drift here is
    /// a change to the bytes that reach a physical machine on the common case.
    func testEveryShippedSingleFilamentPathProducesTheSameArrayAsBefore() {
        // requirements unknown → the [1] fallback → one element
        XCTAssertEqual(AmsMapping.build(usedSlots: [1], trays: [1: 6]), [6])
        // sole used slot is 1 → one element
        XCTAssertEqual(AmsMapping.build(usedSlots: [1], trays: [1: 0]), [0])
        // sole used slot is k > 1 → -1-padded, tray at index k-1
        XCTAssertEqual(AmsMapping.build(usedSlots: [2], trays: [2: 6]), [-1, 6])
        XCTAssertEqual(AmsMapping.build(usedSlots: [3], trays: [3: 6]), [-1, -1, 6])
    }

    // MARK: - Trays that stopped being usable

    /// "The user picked a tray" and "that tray still holds filament" are two questions; the AMS is
    /// live between choosing on step 6 and pressing Start.
    func testStaleFindsAChoiceWhoseTrayIsGoneWhileUnmappedFindsNothing() {
        let loaded = [tray(0, "PLA"), tray(1, "PETG")]
        XCTAssertEqual(AmsMapping.stale(trays: [1: 4], loaded: loaded), [1])
        XCTAssertEqual(AmsMapping.unmapped(usedSlots: [1], trays: [1: 4]), [],
                       "a tray WAS chosen — the problem is that it is no longer there")
    }

    func testAnEmptiedTrayIsStaleEvenThoughItStillExists() {
        XCTAssertEqual(AmsMapping.stale(trays: [1: 0], loaded: [tray(0, "")]), [1])
        XCTAssertEqual(AmsMapping.stale(trays: [1: 0], loaded: [tray(0, nil)]), [1])
        XCTAssertEqual(AmsMapping.stale(trays: [1: 0], loaded: [tray(0, "PLA")]), [])
    }

    func testStaleReportsEverySlotItAffectsInOrder() {
        XCTAssertEqual(AmsMapping.stale(trays: [3: 9, 1: 9, 2: 0], loaded: [tray(0, "PLA")]), [1, 3])
    }

    private func tray(_ globalId: Int, _ type: String?) -> AmsTrayRef {
        AmsTrayRef(unitId: globalId / 4, unitLabel: "AMS", localId: globalId % 4,
                   globalId: globalId, trayType: type, trayColor: nil)
    }

    // MARK: - Hostile input

    /// Slot ids are 1-based. A 0 or a negative would index out of bounds — a trap, on the last screen
    /// before the toolhead moves.
    func testNonPositiveSlotIdsAreDiscardedRatherThanIndexingOutOfBounds() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [0, 1], trays: [0: 9, 1: 3]), [3])
        XCTAssertEqual(AmsMapping.build(usedSlots: [-2], trays: [-2: 9]), [])
        XCTAssertEqual(AmsMapping.unmapped(usedSlots: [0, -1, 2], trays: [:]), [2])
    }

    func testNoUsableSlotsProducesAnEmptyArrayForTheCallerToDecideOn() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [], trays: [1: 0]), [])
    }

    func testADuplicatedSlotResolvesToOneEntry() {
        XCTAssertEqual(AmsMapping.build(usedSlots: [2, 2], trays: [2: 5]), [-1, 5])
    }

    /// A 9-tray machine with a high-numbered slot must not truncate.
    func testAHighSlotCountKeepsEveryPrecedingIndex() {
        let mapping = AmsMapping.build(usedSlots: [1, 4], trays: [1: 0, 4: 128])
        XCTAssertEqual(mapping, [0, -1, -1, 128])
        XCTAssertEqual(mapping.count, 4)
    }
}

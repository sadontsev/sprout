#if os(macOS)
import XCTest
@testable import Sprout

/// The six reasons the Mac print sheet refuses to send, and — as much as the copy — their ORDER.
///
/// `MacPrintGate` had no coverage at all before this file, despite its own doc comment inviting it and
/// despite being the only thing standing between a click and an enqueue the printer cannot execute.
/// It is about to grow a third state (a "press Slice first" remedy), so it gets pinned first: the
/// point of these tests is that the refactor cannot change which sentence a user sees.
///
/// Order matters because the guards are a sequence, not a set. A file with no toolpaths AND no trays
/// reported must say "Nothing to print yet" — the fact about the FILE, which the user can act on —
/// not "No AMS trays reported", which is a fact about the printer and irrelevant to a file that could
/// never print anyway.
final class MacPrintGateTests: XCTestCase {

    // MARK: Fixtures

    private func file(_ type: String?, slicedForModel: String? = nil) -> LibraryFile {
        var f = LibraryFile(id: 7, filename: "plate.gcode.3mf")
        f.fileType = type
        f.slicedForModel = slicedForModel
        return f
    }

    private func tray(_ global: Int, local: Int = 0, type: String? = "PLA") -> AmsTrayRef {
        AmsTrayRef(unitId: 0, unitLabel: "AMS 1", localId: local,
                   globalId: global, trayType: type, trayColor: "FFFFFF")
    }

    /// The healthy case: sliced, this machine, status in, one tray, one slot, mapped and loaded.
    private func evaluate(
        file f: LibraryFile? = nil,
        printerMismatch: Bool = false,
        slicedFor: String? = nil,
        hasStatus: Bool = true,
        loadedTrays: [AmsTrayRef]? = nil,
        usedSlots: [Int] = [1],
        trayBySlot: [Int: Int]? = nil
    ) -> MacPrintProblem? {
        MacPrintGate.evaluate(
            file: f ?? file("gcode.3mf"),
            printerMismatch: printerMismatch,
            slicedFor: slicedFor,
            printerName: "H2C",
            hasStatus: hasStatus,
            loadedTrays: loadedTrays ?? [tray(0)],
            usedSlots: usedSlots,
            trayBySlot: trayBySlot ?? [1: 0]
        )
    }

    // MARK: The happy path

    func testAReadyPrintHasNoProblem() {
        XCTAssertNil(evaluate())
    }

    // MARK: 1 — toolpaths

    /// `hasGcode`, never `isSliced`. A plain project .3mf naming a machine is `isSliced == true` and
    /// has nothing to run; waving it through is the pair CLAUDE.md's table names.
    func testAPlainProjectThreeMFIsRefusedEvenThoughItLooksSliced() {
        let f = file("3mf", slicedForModel: "Creality K2 Pro")
        XCTAssertTrue(LibraryFileCaps.isSliced(f), "precondition: the label says sliced")
        let p = evaluate(file: f)
        XCTAssertEqual(p?.title, "Nothing to print yet")
        XCTAssertEqual(p?.terminal, true)
    }

    func testAnStlIsRefused() {
        XCTAssertEqual(evaluate(file: file("stl"))?.title, "Nothing to print yet")
    }

    /// ORDER: the file's own problem outranks every fact about the printer.
    func testNoToolpathsOutranksNoTraysAndNoStatus() {
        let p = evaluate(file: file("3mf"), hasStatus: false, loadedTrays: [], trayBySlot: [:])
        XCTAssertEqual(p?.title, "Nothing to print yet",
                       "a file that can never print here must not be reported as a printer problem")
    }

    // MARK: 2 — the wrong machine

    func testGcodeForAnotherPrinterIsTerminal() {
        let p = evaluate(printerMismatch: true, slicedFor: "X1 Carbon")
        XCTAssertEqual(p?.title, "Sliced for another printer")
        XCTAssertEqual(p?.terminal, true)
        XCTAssertTrue(p!.message.contains("X1 Carbon"), "name the machine it WAS sliced for")
        XCTAssertTrue(p!.message.contains("H2C"), "and the one it is not")
    }

    /// ORDER: a mismatch outranks the AMS, because reslicing is the remedy either way.
    func testTheWrongMachineOutranksTheAms() {
        XCTAssertEqual(evaluate(printerMismatch: true, loadedTrays: [], trayBySlot: [:])?.title,
                       "Sliced for another printer")
    }

    // MARK: 3 — "no trays" vs "has not answered"

    /// Two questions, deliberately two guards. "Still connecting" is not "reports no trays", and
    /// printing the second at a printer that simply has not answered is the same shape as rendering
    /// "you have none" from a response that also means "we could not ask".
    func testNoStatusYetIsNotTheSameAsNoTrays() {
        let waiting = evaluate(hasStatus: false, loadedTrays: [], trayBySlot: [:])
        XCTAssertEqual(waiting?.title, "Waiting for the printer")
        XCTAssertNotEqual(waiting?.terminal, true, "it clears on its own — not terminal")

        let none = evaluate(hasStatus: true, loadedTrays: [], trayBySlot: [:])
        XCTAssertEqual(none?.title, "No AMS trays reported")
        XCTAssertNotEqual(none?.terminal, true, "loading a spool fixes it")
    }

    func testWaitingOutranksNoTrays() {
        XCTAssertEqual(evaluate(hasStatus: false, loadedTrays: [])?.title, "Waiting for the printer")
    }

    // MARK: 4 — slots the mapping cannot address

    func testASlotBeyondTheMappingIsNamedAndTerminal() {
        let p = evaluate(usedSlots: [1, 99], trayBySlot: [1: 0, 99: 0])
        XCTAssertEqual(p?.title, "Too many filaments")
        XCTAssertEqual(p?.terminal, true)
        XCTAssertTrue(p!.message.contains("99"), "name the slot rather than truncating silently")
    }

    // MARK: 5 — every used slot has a tray

    /// One unmapped slot names it; the singular/plural copy differs and both are user-facing.
    func testOneUnmappedSlotIsNamed() {
        let p = evaluate(usedSlots: [1, 2], trayBySlot: [1: 0])
        XCTAssertEqual(p?.title, "Filament 2 has no tray")
        XCTAssertTrue(p!.message.contains("2 filaments"))
    }

    func testSeveralUnmappedSlotsShareOneTitle() {
        let p = evaluate(loadedTrays: [tray(0)], usedSlots: [1, 2, 3], trayBySlot: [:])
        XCTAssertEqual(p?.title, "Some filaments have no tray")
        for n in [1, 2, 3] { XCTAssertTrue(p!.message.contains("filament \(n)")) }
    }

    /// A single-filament plate gets copy that does not say "filament 1" — there is only one.
    func testASingleFilamentPlateGetsSimplerCopy() {
        let p = evaluate(usedSlots: [1], trayBySlot: [:])
        XCTAssertEqual(p?.message, "Choose which AMS tray to print from.")
    }

    // MARK: 6 — the tray still holds filament

    /// The AMS is live while the sheet is open, so a spool pulled AFTER the choice must be caught.
    func testASpoolRemovedAfterTheChoiceIsCaught() {
        let p = evaluate(loadedTrays: [tray(1)], trayBySlot: [1: 0])   // chose tray 0, only 1 is loaded
        XCTAssertEqual(p?.title, "That tray is empty now")
    }

    /// ORDER: an unmapped slot outranks a stale one — you cannot be told a tray emptied for a slot
    /// you never assigned.
    func testUnmappedOutranksStale() {
        let p = evaluate(loadedTrays: [tray(0)], usedSlots: [1, 2], trayBySlot: [1: 9])
        XCTAssertEqual(p?.title, "Filament 2 has no tray")
    }

    // MARK: Copy invariants

    /// Every refusal says something, and terminal ones are the two that cannot be fixed here.
    func testEveryRefusalCarriesBothATitleAndAMessage() {
        let cases: [MacPrintProblem?] = [
            evaluate(file: file("3mf")),
            evaluate(printerMismatch: true),
            evaluate(hasStatus: false),
            evaluate(loadedTrays: []),
            evaluate(usedSlots: [1, 99], trayBySlot: [1: 0, 99: 0]),
            evaluate(usedSlots: [1, 2], trayBySlot: [1: 0]),
            evaluate(loadedTrays: [tray(1)], trayBySlot: [1: 0]),
        ]
        for p in cases {
            let problem = try? XCTUnwrap(p)
            XCTAssertFalse(problem?.title.isEmpty ?? true)
            XCTAssertFalse(problem?.message.isEmpty ?? true)
        }
    }
}
#endif

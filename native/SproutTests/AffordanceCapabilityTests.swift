import XCTest
@testable import Sprout

/// The predicates that decide whether an affordance is offered at all.
///
/// Each one here replaced a NEARBY question that the UI had been asking instead — the recurring bug
/// in this codebase. They are tested together because the point is the CONTRAST: the pairs answer
/// differently for exactly the payloads that shipped the bug.
final class AffordanceCapabilityTests: XCTestCase {

    private func file(
        id: Int = 1,
        filename: String = "model.3mf",
        fileType: String?,
        slicedForModel: String? = nil
    ) -> LibraryFile {
        LibraryFile(id: id, filename: filename, fileType: fileType, slicedForModel: slicedForModel)
    }

    // MARK: - isSliced vs hasGcode

    /// The live payload that shipped the bug: a plain project `.3mf` naming a slicer target it was
    /// never sliced for. It carries no toolpaths, and `/library/files/{id}/gcode` answers 404 —
    /// verified against the running server.
    func testAPlain3mfNamingASlicerTargetIsSlicedButHasNoGcode() {
        let f = file(filename: "cr.3mf", fileType: "3mf", slicedForModel: "Creality K2 Pro")
        XCTAssertTrue(LibraryFileCaps.isSliced(f), "the badge is right: something prepared this")
        XCTAssertFalse(LibraryFileCaps.hasGcode(f), "…but there are no toolpaths behind it")
    }

    func testAGcode3mfAnswersBothQuestionsYes() {
        let f = file(filename: "cr.gcode.3mf", fileType: "gcode.3mf", slicedForModel: "H2C")
        XCTAssertTrue(LibraryFileCaps.isSliced(f))
        XCTAssertTrue(LibraryFileCaps.hasGcode(f))
    }

    /// A `gcode.3mf` that forgot to say which machine it was for still has toolpaths — `hasGcode`
    /// must not lean on `slicedForModel` the way `isSliced` does.
    func testGcodeWithNoSlicedForModelStillHasToolpaths() {
        XCTAssertTrue(LibraryFileCaps.hasGcode(file(fileType: "gcode.3mf")))
        XCTAssertTrue(LibraryFileCaps.hasGcode(file(fileType: "GCODE.3MF")))
        XCTAssertTrue(LibraryFileCaps.hasGcode(file(fileType: "gcode")))
    }

    func testAPlainModelIsNeitherSlicedNorHasGcode() {
        for type in ["stl", "3mf", "STL", nil] {
            let f = file(fileType: type)
            XCTAssertFalse(LibraryFileCaps.isSliced(f), "type \(type ?? "nil")")
            XCTAssertFalse(LibraryFileCaps.hasGcode(f), "type \(type ?? "nil")")
        }
    }

    /// An empty `sliced_for_model` is the server saying "no", not saying something.
    func testAnEmptySlicedForModelIsNotASlicerTarget() {
        XCTAssertFalse(LibraryFileCaps.isSliced(file(fileType: "3mf", slicedForModel: "")))
    }

    // MARK: - isStl

    /// The 3D viewer is an STL parser, so "is a model" is not the question — `.3mf` is a zip
    /// container it cannot open.
    func testOnlyAnStlCanOpenInTheMeshViewer() {
        XCTAssertTrue(LibraryFileCaps.isStl(file(fileType: "stl")))
        XCTAssertTrue(LibraryFileCaps.isStl(file(fileType: "STL")))
        XCTAssertFalse(LibraryFileCaps.isStl(file(fileType: "3mf")))
        XCTAssertFalse(LibraryFileCaps.isStl(file(fileType: "gcode.3mf")))
        XCTAssertFalse(LibraryFileCaps.isStl(file(fileType: nil)))
        // Not a substring match: "stl" has to BE the type.
        XCTAssertFalse(LibraryFileCaps.isStl(file(fileType: "stlx")))
    }

    // MARK: - reprintArchiveId vs "the print is complete"

    private func finished(archiveId: Int?) -> PrinterStatus {
        var s = PrinterStatus()
        s.connected = true
        s.state = "FINISH"
        s.currentArchiveId = archiveId
        return s
    }

    /// Both halves of the split. The state says "complete" either way; only the archive id says
    /// whether there is anything to re-queue.
    func testCompleteWithoutAnArchiveOffersNothingToReprint() {
        let vm = Dash.present(finished(archiveId: nil))
        XCTAssertEqual(vm.kind, .complete)
        XCTAssertNil(vm.reprintArchiveId)
    }

    func testCompleteWithAnArchiveCarriesTheReprintTarget() {
        let vm = Dash.present(finished(archiveId: 126))
        XCTAssertEqual(vm.kind, .complete)
        XCTAssertEqual(vm.reprintArchiveId, 126)
    }

    /// The id is carried on every live state, not only on `.complete` — the Jobs tab and the
    /// dashboard read the same VM, and a running print already has its archive row.
    func testTheReprintTargetSurvivesEveryReachableState() {
        for state in ["RUNNING", "PAUSE", "FINISH"] {
            var s = finished(archiveId: 42)
            s.state = state
            XCTAssertEqual(Dash.present(s).reprintArchiveId, 42, "state \(state)")
        }
    }

    /// A printer that is not answering has no reprint target to offer either — the VM short-circuits
    /// before it ever reads the field, and the button must not appear live over a dead machine.
    func testOfflineAndUnknownHaveNoReprintTarget() {
        var offline = finished(archiveId: 7)
        offline.connected = false
        XCTAssertNil(Dash.present(offline).reprintArchiveId)
        XCTAssertNil(Dash.present(nil).reprintArchiveId)
    }
}

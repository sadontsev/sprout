import XCTest

@testable import Sprout

/// Which plate of a multi-plate file is printing.
///
/// The plate-render endpoint is indexed and DEFAULTS TO 1, so getting this wrong is silent: the card
/// shows a real picture of the wrong plate, which reads as working. Reported from a live print sent
/// from Bambu Handy — plate 2 or 3 running, plate 1 on the card.
final class PlateIndexTests: XCTestCase {

    func testReadsThePlateTheMachineIsExecuting() {
        XCTAssertEqual(PrintArt.plateIndex(gcodeFile: "/data/Metadata/plate_3.gcode"), 3)
        XCTAssertEqual(PrintArt.plateIndex(gcodeFile: "/data/Metadata/plate_1.gcode"), 1)
        XCTAssertEqual(PrintArt.plateIndex(gcodeFile: "/data/Metadata/plate_12.gcode"), 12)
    }

    /// nil, not 1. "Plate 1" and "no idea which plate" are different answers, and conflating them is
    /// how the endpoint's default became the bug.
    func testNilWhenNothingSays() {
        XCTAssertNil(PrintArt.plateIndex(gcodeFile: nil))
        XCTAssertNil(PrintArt.plateIndex(gcodeFile: ""))
        XCTAssertNil(PrintArt.plateIndex(gcodeFile: "/data/Metadata/plate_.gcode"))
        XCTAssertNil(PrintArt.plateIndex(gcodeFile: "/data/whatever.gcode"))
    }

    /// The executing file wins over the reported field. This printer already reports
    /// `active_extruder` wrongly, so the artefact outranks the report.
    func testTheExecutingFileOutranksTheReportedId() {
        XCTAssertEqual(
            PrintArt.plateIndex(gcodeFile: "/data/Metadata/plate_3.gcode", currentPlateId: 1), 3)
    }

    func testFallsBackToTheReportedIdWhenThereIsNoFile() {
        XCTAssertEqual(PrintArt.plateIndex(gcodeFile: nil, currentPlateId: 2), 2)
        XCTAssertNil(PrintArt.plateIndex(gcodeFile: nil, currentPlateId: 0), "0 is not a plate")
    }

    /// Searched backwards: a user folder may itself contain `plate_2`, and the segment that decides
    /// is the last one.
    func testTheLastSegmentDecides() {
        XCTAssertEqual(
            PrintArt.plateIndex(gcodeFile: "/data/plate_2_spares/Metadata/plate_4.gcode"), 4)
    }

    /// Decoded straight off the wire, because the field was not modelled at all until now — that
    /// absence is what made the plate unknowable.
    func testTheStatusCarriesThePlate() throws {
        // `connected` and `state` are non-optional, and Swift's synthesized decoder ignores
        // property defaults, so they are required here even though this test is about neither.
        let json = Data(
            #"{"connected":true,"state":"RUNNING","gcode_file":"/data/Metadata/plate_3.gcode","current_plate_id":3}"#
                .utf8)
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let status = try dec.decode(PrinterStatus.self, from: json)
        XCTAssertEqual(status.gcodeFile, "/data/Metadata/plate_3.gcode")
        XCTAssertEqual(status.currentPlateId?.int, 3)
        XCTAssertEqual(
            PrintArt.plateIndex(gcodeFile: status.gcodeFile, currentPlateId: status.currentPlateId?.int), 3)
    }
}

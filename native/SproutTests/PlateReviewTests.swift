import Foundation
import XCTest
@testable import Sprout

// Real shapes captured from the live backend (cube20.gcode.3mf).
private let PLATES = PlatesResponse(
    fileId: 2,
    filename: "cube20.gcode.3mf",
    plates: [
        PlateInfo(
            index: 1,
            name: "cube20.stl",
            objectCount: 1,
            hasThumbnail: false,
            printTimeSeconds: 738,
            filamentUsedGrams: 3.75,
            filaments: [PlateFilament(slotId: 1, type: "PLA", color: "#00AE42", usedGrams: 3.8, usedMeters: 1.24)]
        )
    ],
    isMultiPlate: false,
    embeddedPrinter: "Bambu Lab A1 0.4 nozzle",
    embeddedProcess: "0.20mm Standard @BBL A1"
)

private let META = FileMetadata(
    totalLayers: 100,
    layerHeight: 0.2,
    nozzleTemperature: 220,
    bedType: "Cool Plate",
    filamentUsedG: 3.75,
    printTimeSeconds: 738,
    filamentSlots: [FileMetadata.FilamentSlot(slotId: 1, usedG: 3.75, type: "PLA", color: "#00AE42")]
)

final class PlateReviewTests: XCTestCase {

    // MARK: - build

    func testMergesPlateAndMetadataIntoRenderReadyVM() {
        let vm = PlateReview.build(plates: PLATES, meta: META, plateIndex: 1)
        XCTAssertEqual(vm.plateIndex, 1)
        XCTAssertEqual(vm.plateCount, 1)
        XCTAssertFalse(vm.isMultiPlate)
        assertClose(vm.timeSeconds, 738)
        assertClose(vm.grams, 3.75)
        XCTAssertEqual(vm.layers, 100)
        assertClose(vm.layerHeight, 0.2)
        assertClose(vm.heightMm, 20)          // 100 × 0.2
        XCTAssertEqual(vm.nozzleTemp, 220)
        XCTAssertEqual(vm.bedType, "Cool Plate")
        XCTAssertEqual(vm.objectCount, 1)
        XCTAssertEqual(vm.printer, "Bambu Lab A1 0.4 nozzle")
        XCTAssertEqual(vm.process, "0.20mm Standard @BBL A1")
        XCTAssertEqual(vm.filaments, [
            ReviewFilament(slot: 1, type: "PLA", color: "#00AE42", grams: 3.8, meters: 1.24)
        ])
    }

    func testPrefersPlateFilamentListFallingBackToMetadataSlots() {
        var plates = PLATES
        plates.plates = [PlateInfo(index: 1)]
        let vm = PlateReview.build(plates: plates, meta: META, plateIndex: 1)
        XCTAssertEqual(vm.filaments, [
            ReviewFilament(slot: 1, type: "PLA", color: "#00AE42", grams: 3.75, meters: nil)
        ])
    }

    /// An unsliced or partially parsed plate reports `filaments: []` — an empty list must not win
    /// over the metadata slots.
    func testEmptyPlateFilamentListFallsThroughToMetadataSlots() {
        var plates = PLATES
        plates.plates = [PlateInfo(index: 1, filaments: [])]
        let vm = PlateReview.build(plates: plates, meta: META, plateIndex: 1)
        XCTAssertEqual(vm.filaments.count, 1)
        assertClose(vm.filaments.first?.grams, 3.75)
        XCTAssertNil(vm.filaments.first?.meters)
    }

    func testFallsBackToFirstPlateWhenRequestedIndexIsAbsent() {
        let vm = PlateReview.build(plates: PLATES, meta: META, plateIndex: 5)
        XCTAssertEqual(vm.plateIndex, 1)
    }

    func testIsNullSafeWithNoData() {
        let vm = PlateReview.build(plates: nil, meta: nil, plateIndex: 1)
        XCTAssertNil(vm.timeSeconds)
        XCTAssertNil(vm.layers)
        XCTAssertNil(vm.heightMm)
        XCTAssertEqual(vm.filaments, [])
        XCTAssertEqual(vm.plateCount, 0)
        XCTAssertEqual(vm.plateIndex, 1)
        XCTAssertFalse(vm.isMultiPlate)
        XCTAssertNil(vm.printer)
        XCTAssertNil(vm.process)
        XCTAssertNil(vm.objectCount)
        XCTAssertNil(vm.bedType)
    }

    func testComputesHeightMmOnlyWhenBothLayersAndLayerHeightAreKnown() {
        assertClose(PlateReview.build(plates: nil, meta: FileMetadata(totalLayers: 110, layerHeight: 0.2)).heightMm, 22)
        XCTAssertNil(PlateReview.build(plates: nil, meta: FileMetadata(totalLayers: 110)).heightMm)
        XCTAssertNil(PlateReview.build(plates: nil, meta: FileMetadata(layerHeight: 0.2)).heightMm)
    }

    func testHeightMmRoundsToTwoDecimals() {
        assertClose(PlateReview.build(plates: nil, meta: FileMetadata(totalLayers: 137, layerHeight: 0.08)).heightMm, 10.96)
        assertClose(PlateReview.build(plates: nil, meta: FileMetadata(totalLayers: 10, layerHeight: 0.125)).heightMm, 1.25)
        // 3 dp in, 2 dp out: 7 × 0.111 = 0.777.
        assertClose(PlateReview.build(plates: nil, meta: FileMetadata(totalLayers: 7, layerHeight: 0.111)).heightMm, 0.78)
    }

    func testDefaultsToPlateOne() {
        XCTAssertEqual(PlateReview.build(plates: PLATES, meta: META).plateIndex, 1)
        XCTAssertEqual(PlateReview.build(plates: nil, meta: nil).plateIndex, 1)
    }

    func testEmptyPlatesArrayKeepsTheRequestedIndex() {
        var plates = PLATES
        plates.plates = []
        let vm = PlateReview.build(plates: plates, meta: META, plateIndex: 3)
        XCTAssertEqual(vm.plateCount, 0)
        XCTAssertEqual(vm.plateIndex, 3)
        // Plate-level figures are gone, so the metadata has to carry time and mass.
        assertClose(vm.timeSeconds, 738)
        assertClose(vm.grams, 3.75)
    }

    func testPicksTheRequestedPlateOutOfSeveral() {
        var plates = PLATES
        plates.isMultiPlate = true
        plates.plates = [
            PlateInfo(index: 1, printTimeSeconds: 100, filamentUsedGrams: 1),
            PlateInfo(index: 2, objectCount: 4, printTimeSeconds: 900, filamentUsedGrams: 12.5)
        ]
        let vm = PlateReview.build(plates: plates, meta: META, plateIndex: 2)
        XCTAssertEqual(vm.plateIndex, 2)
        XCTAssertEqual(vm.plateCount, 2)
        XCTAssertTrue(vm.isMultiPlate)
        XCTAssertEqual(vm.objectCount, 4)
        assertClose(vm.timeSeconds, 900)
        assertClose(vm.grams, 12.5)
    }

    func testPlateFiguresWinOverMetadataFigures() {
        var plates = PLATES
        plates.plates = [PlateInfo(index: 1, printTimeSeconds: 1200, filamentUsedGrams: 9)]
        let vm = PlateReview.build(plates: plates, meta: META, plateIndex: 1)
        assertClose(vm.timeSeconds, 1200)
        assertClose(vm.grams, 9)
    }

    func testPrinterFallsBackToSlicedForModel() {
        var plates = PLATES
        plates.embeddedPrinter = nil
        plates.embeddedProcess = nil
        var meta = META
        meta.slicedForModel = "Bambu Lab A1"
        let vm = PlateReview.build(plates: plates, meta: meta, plateIndex: 1)
        XCTAssertEqual(vm.printer, "Bambu Lab A1")
        XCTAssertNil(vm.process)     // no metadata equivalent for the process preset
    }

    func testMissingSlotIdAndTypeGetPlaceholders() {
        var plates = PLATES
        plates.plates = [PlateInfo(index: 1, filaments: [PlateFilament(color: "#FFFFFF")])]
        let vm = PlateReview.build(plates: plates, meta: nil, plateIndex: 1)
        XCTAssertEqual(vm.filaments, [ReviewFilament(slot: 0, type: "—", color: "#FFFFFF", grams: nil, meters: nil)])
    }

    /// The raw slicer value is kept as-is — the render site decides what is a usable colour.
    func testColourIsNotNormalised() {
        var plates = PLATES
        plates.plates = [PlateInfo(index: 1, filaments: [PlateFilament(slotId: 1, type: "PLA", color: "00AE42FF")])]
        XCTAssertEqual(PlateReview.build(plates: plates, meta: nil).filaments.first?.color, "00AE42FF")
    }

    // MARK: - Numeric edges

    func testNonFiniteAndExplicitlyNullNumbersReadAsNil() {
        let meta = FileMetadata(
            totalLayers: LooseNumber(Double.nan),
            layerHeight: LooseNumber(Double.infinity),
            nozzleTemperature: LooseNumber(nil as Double?),
            printTimeSeconds: LooseNumber(-Double.infinity)
        )
        let vm = PlateReview.build(plates: nil, meta: meta)
        XCTAssertNil(vm.layers)
        XCTAssertNil(vm.layerHeight)
        XCTAssertNil(vm.heightMm)
        XCTAssertNil(vm.nozzleTemp)
        XCTAssertNil(vm.timeSeconds)
    }

    /// The WebSocket feed stringifies numerics; `LooseNumber` absorbs that, and everything
    /// downstream must behave identically to the REST shape.
    func testStringifiedNumbersFlowThrough() throws {
        let meta = FileMetadata(
            totalLayers: try loose("\"100\""),
            layerHeight: try loose("\"0.2\""),
            nozzleTemperature: try loose("\"220\""),
            printTimeSeconds: try loose("\"738\"")
        )
        let vm = PlateReview.build(plates: nil, meta: meta)
        XCTAssertEqual(vm.layers, 100)
        assertClose(vm.layerHeight, 0.2)
        assertClose(vm.heightMm, 20)
        XCTAssertEqual(vm.nozzleTemp, 220)
        assertClose(vm.timeSeconds, 738)
    }

    /// `Int(_: Double)` traps outside Int's range — an absurd payload must produce a dash, not a
    /// crash.
    func testOutOfRangeCountsDoNotTrap() {
        for absurd in [1e300, -1e300, Double.greatestFiniteMagnitude] {
            let vm = PlateReview.build(plates: nil, meta: FileMetadata(totalLayers: LooseNumber(absurd), nozzleTemperature: LooseNumber(absurd)))
            XCTAssertNil(vm.layers)
            XCTAssertNil(vm.nozzleTemp)
        }
    }

    func testNozzleTempRoundsToNearestDegree() {
        XCTAssertEqual(PlateReview.build(plates: nil, meta: FileMetadata(nozzleTemperature: 219.6)).nozzleTemp, 220)
        XCTAssertEqual(PlateReview.build(plates: nil, meta: FileMetadata(nozzleTemperature: 219.4)).nozzleTemp, 219)
    }

    /// `layers` is rounded for display but the height must come from the raw figures.
    func testFractionalLayerCountDoesNotDistortHeight() {
        let vm = PlateReview.build(plates: nil, meta: FileMetadata(totalLayers: 100.6, layerHeight: 0.2))
        XCTAssertEqual(vm.layers, 101)
        assertClose(vm.heightMm, 20.12)
    }

    // MARK: - fmtSeconds

    func testFmtSecondsFormatsMinutesAndHours() {
        XCTAssertEqual(PlateReview.fmtSeconds(738), "12 min")
        XCTAssertEqual(PlateReview.fmtSeconds(3660), "1 h 1 min")
        XCTAssertEqual(PlateReview.fmtSeconds(0), "—")
        XCTAssertEqual(PlateReview.fmtSeconds(nil), "—")
    }

    func testFmtSecondsRoundsToTheNearestMinute() {
        XCTAssertEqual(PlateReview.fmtSeconds(30), "1 min")      // exactly half a minute rounds up
        XCTAssertEqual(PlateReview.fmtSeconds(29), "0 min")
        XCTAssertEqual(PlateReview.fmtSeconds(3599), "1 h 0 min")
        XCTAssertEqual(PlateReview.fmtSeconds(3600), "1 h 0 min")
    }

    func testFmtSecondsRejectsUnusableInput() {
        XCTAssertEqual(PlateReview.fmtSeconds(-1), "—")
        XCTAssertEqual(PlateReview.fmtSeconds(Double.nan), "—")
        XCTAssertEqual(PlateReview.fmtSeconds(Double.infinity), "—")
        // Would trap in the Double -> Int conversion if it were unguarded.
        XCTAssertEqual(PlateReview.fmtSeconds(1e300), "—")
    }

    /// Big durations must not pick up a locale's grouping separator ("2,777 h").
    func testFmtSecondsHasNoGroupingSeparator() {
        XCTAssertEqual(PlateReview.fmtSeconds(10_000_000), "2777 h 47 min")
    }

    // MARK: - Helpers

    private func assertClose(
        _ actual: Double?,
        _ expected: Double,
        accuracy: Double = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected \(expected), got nil", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, accuracy: accuracy, file: file, line: line)
    }

    private func loose(_ json: String) throws -> LooseNumber {
        try JSONDecoder().decode(LooseNumber.self, from: Data(json.utf8))
    }
}

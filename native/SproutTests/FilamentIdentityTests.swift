import XCTest
@testable import Sprout

// The live spool this module exists for: AMS 1 slot 3 holds "Clay Brown" Bambu PLA Wood, a brown the
// HSL namer calls "Orange". Every fixture below is that record or a deliberate variation on it.
private let CLAY_BROWN = "#8B5A2B"

private func ref(
    _ localId: Int,
    _ trayType: String? = nil,
    _ trayColor: String? = nil,
    unit unitId: Int = 0
) -> AmsTrayRef {
    AmsTrayRef(
        unitId: unitId,
        unitLabel: unitId >= 128 ? "AMS HT" : "AMS \(unitId + 1)",
        localId: localId,
        globalId: AmsTopology.globalTrayId(unitId: unitId, localId: localId),
        trayType: trayType,
        trayColor: trayColor
    )
}

private func spool(
    colorName: String? = nil,
    rgba: String? = nil,
    slicerFilamentName: String? = nil
) -> AssignmentLike.SpoolLike {
    AssignmentLike.SpoolLike(colorName: colorName, rgba: rgba, slicerFilamentName: slicerFilamentName)
}

private func woodSpoolAssignment(tray: Int = 2, unit: Int? = 0) -> AssignmentLike {
    AssignmentLike(
        trayId: tray,
        amsId: unit,
        spool: spool(colorName: "Clay Brown", rgba: "8B5A2BFF", slicerFilamentName: "Bambu PLA Wood")
    )
}

// MARK: - Naming precedence

final class FilamentIdentityResolveTests: XCTestCase {

    /// The bug this whole module answers: the namer really does call that brown "Orange", so the
    /// spool's own word for it has to win or the row contradicts its own swatch.
    func testComputedNameOfTheLiveSpoolIsWrong() {
        XCTAssertEqual(FilamentColor.name(CLAY_BROWN), "Orange")
    }

    func testVendorColourNameBeatsTheComputedOne() {
        let id = FilamentIdentity.resolve(
            colorHex: CLAY_BROWN,
            spoolColorName: "Clay Brown",
            material: "PLA",
            product: "Bambu PLA Wood"
        )
        XCTAssertEqual(id.colorName, "Clay Brown")
        XCTAssertEqual(id.colorHex, CLAY_BROWN)
        XCTAssertEqual(id.material, "PLA")
        XCTAssertEqual(id.product, "Bambu PLA Wood")
    }

    /// No inventory record behind the tray -> the computed name is the fallback, not nothing: a
    /// swatch alone cannot say "white".
    func testComputedNameIsTheFallback() {
        let id = FilamentIdentity.resolve(colorHex: "#FFFFFF", spoolColorName: nil, material: "PLA", product: nil)
        XCTAssertEqual(id.colorName, "White")
        XCTAssertEqual(id.title, "White PLA")
    }

    /// Inventory fields are free text and come back blank for unrecognised spools.
    func testBlankAndWhitespaceFieldsAreUnknownNotValues() {
        let id = FilamentIdentity.resolve(colorHex: CLAY_BROWN, spoolColorName: "   ", material: " PLA ", product: "")
        XCTAssertEqual(id.colorName, "Orange")   // fell through to the computed name
        XCTAssertEqual(id.material, "PLA")       // trimmed
        XCTAssertNil(id.product)
    }

    func testUnknownColourLeavesBothHexAndName() {
        let id = FilamentIdentity.resolve(colorHex: nil, spoolColorName: nil, material: "PETG", product: nil)
        XCTAssertNil(id.colorHex)
        XCTAssertNil(id.colorName)
        XCTAssertEqual(id.title, "PETG")
    }

    /// Alpha "00" is Bambu's "colour unset" sentinel — it must not become a black spool with a name.
    func testUnsetAlphaIsNotAColour() {
        let id = FilamentIdentity.resolve(colorHex: "00000000", spoolColorName: nil, material: "PLA", product: nil)
        XCTAssertNil(id.colorHex)
        XCTAssertNil(id.colorName)
    }

    func testAcceptsRawRgbaAndAlreadyNormalisedHex() {
        XCTAssertEqual(
            FilamentIdentity.resolve(colorHex: "8B5A2BFF", spoolColorName: nil, material: nil, product: nil).colorHex,
            CLAY_BROWN
        )
        XCTAssertEqual(
            FilamentIdentity.resolve(colorHex: CLAY_BROWN, spoolColorName: nil, material: nil, product: nil).colorHex,
            CLAY_BROWN
        )
    }

    /// A "product" that only repeats the material names nothing new.
    func testProductEqualToTheMaterialIsDropped() {
        let id = FilamentIdentity.resolve(colorHex: nil, spoolColorName: "Jet Black", material: "PLA", product: "pla")
        XCTAssertNil(id.product)
        XCTAssertEqual(id.line, "Jet Black PLA")
    }

    func testNothingKnownNamesNothing() {
        let id = FilamentIdentity.resolve(colorHex: nil, spoolColorName: nil, material: nil, product: nil)
        XCTAssertEqual(id.title, "")
        XCTAssertEqual(id.line, "")
    }
}

// MARK: - Display lines

final class FilamentIdentityLineTests: XCTestCase {

    /// What the Hardware tab renders today, and what the wizard's Material step must match.
    func testTitleIsColourThenMaterial() {
        let id = FilamentIdentity.resolve(
            colorHex: CLAY_BROWN, spoolColorName: "Clay Brown", material: "PLA", product: "Bambu PLA Wood"
        )
        XCTAssertEqual(id.title, "Clay Brown PLA")
    }

    /// The one-line form drops the material only because the product name already contains that word.
    func testLineDropsAMaterialTheProductAlreadySays() {
        let id = FilamentIdentity.resolve(
            colorHex: CLAY_BROWN, spoolColorName: "Clay Brown", material: "PLA", product: "Bambu PLA Wood"
        )
        XCTAssertEqual(id.line, "Clay Brown · Bambu PLA Wood")
    }

    /// Word-wise, not substring-wise: "PETG" is inside "PETG-CF", but a PETG-CF product on a PETG tray
    /// is a different filament and the row must keep saying both.
    func testLineKeepsAMaterialTheProductOnlyResembles() {
        let id = FilamentIdentity.resolve(
            colorHex: "#FF0000", spoolColorName: "Red", material: "PETG", product: "Bambu PETG-CF"
        )
        XCTAssertEqual(id.line, "Red PETG · Bambu PETG-CF")
    }

    /// A third-party name that says nothing about the material must not cost the material.
    func testLineKeepsTheMaterialForAnUnrelatedProductName() {
        let id = FilamentIdentity.resolve(
            colorHex: "#FF0000", spoolColorName: nil, material: "PLA", product: "Polymaker PolyLite"
        )
        XCTAssertEqual(id.line, "Red PLA · Polymaker PolyLite")
    }

    func testLineFallsBackToTheTitleWithoutAProduct() {
        let id = FilamentIdentity.resolve(colorHex: "#FF0000", spoolColorName: nil, material: "PLA", product: nil)
        XCTAssertEqual(id.line, "Red PLA")
        XCTAssertEqual(id.line, id.title)
    }

    func testProductAloneStillNamesTheFilament() {
        let id = FilamentIdentity.resolve(
            colorHex: nil, spoolColorName: nil, material: nil, product: "Bambu PLA Wood"
        )
        XCTAssertEqual(id.title, "")
        XCTAssertEqual(id.line, "Bambu PLA Wood")
    }
}

// MARK: - Per-tray identity

final class FilamentMatchIdentityTests: XCTestCase {

    /// The live case end to end: AMS 1 slot 3 must read as its spool on every screen.
    func testTrayIdentityUsesTheAssignedSpool() {
        let id = FilamentMatch.identity(for: ref(2, "PLA", "8B5A2BFF"), in: [woodSpoolAssignment()])
        XCTAssertEqual(id.title, "Clay Brown PLA")
        XCTAssertEqual(id.line, "Clay Brown · Bambu PLA Wood")
        XCTAssertEqual(id.colorHex, CLAY_BROWN)
    }

    func testTrayWithNoAssignmentFallsBackToTheTrayItself() {
        let id = FilamentMatch.identity(for: ref(0, "PLA", "FF0000FF"), in: [])
        XCTAssertEqual(id.line, "Red PLA")
        XCTAssertNil(id.product)
    }

    /// An empty tray names nothing, so the row can say "Empty" instead of half a name.
    func testEmptyTrayNamesNothing() {
        let id = FilamentMatch.identity(for: ref(1), in: [woodSpoolAssignment()])
        XCTAssertEqual(id.line, "")
        XCTAssertEqual(id.title, "")
    }

    /// The tray's own colour wins; the spool's is the fallback for a tray whose colour the printer
    /// does not know.
    func testTrayColourWinsAndSpoolColourFillsTheGap() {
        let assigns = [woodSpoolAssignment()]
        XCTAssertEqual(FilamentMatch.identity(for: ref(2, "PLA", "112233FF"), in: assigns).colorHex, "#112233")
        XCTAssertEqual(FilamentMatch.identity(for: ref(2, "PLA", nil), in: assigns).colorHex, CLAY_BROWN)
        XCTAssertEqual(FilamentMatch.identity(for: ref(2, "PLA", "00000000"), in: assigns).colorHex, CLAY_BROWN)
    }

    /// Both ids must match: AMS 2 slot 3 must not inherit AMS 1 slot 3's spool.
    func testIdentityDoesNotCrossUnits() {
        let id = FilamentMatch.identity(for: ref(2, "PLA", "FF0000FF", unit: 1), in: [woodSpoolAssignment()])
        XCTAssertEqual(id.line, "Red PLA")
    }

    /// A legacy assignment written before assignments carried a unit id still names its tray.
    func testLegacyAssignmentWithoutAUnitStillMatches() {
        let id = FilamentMatch.identity(for: ref(2, "PLA", "FF0000FF"), in: [woodSpoolAssignment(unit: nil)])
        XCTAssertEqual(id.line, "Clay Brown · Bambu PLA Wood")
        XCTAssertEqual(id.colorHex, "#FF0000")   // the tray's own colour still wins over the spool's
    }

    /// The Material step reads its rows through `LoadedFilament`, so the same answer has to survive
    /// the trip through preset matching.
    func testLoadedFilamentCarriesTheSameIdentity() throws {
        let out = FilamentMatch.loaded(
            trays: [ref(2, "PLA", "8B5A2BFF")],
            assignments: [woodSpoolAssignment()],
            presets: [Preset(id: "a", name: "Bambu PLA Basic @BBL A1", source: nil)]
        )
        let row = try XCTUnwrap(out.first)
        XCTAssertEqual(row.identity.title, "Clay Brown PLA")
        XCTAssertEqual(row.identity.product, "Bambu PLA Wood")
        XCTAssertEqual(row.product, "Bambu PLA Wood")
    }
}

// MARK: - Review rows

final class FilamentIdentityReviewRowTests: XCTestCase {

    /// The plate as the slicer left it: green PLA. Colour and type are its defaults.
    private let plate = [ReviewFilament(slot: 1, type: "PLA", color: "#00AE42", grams: 152.1, meters: 51.0)]

    private var selection: FilamentIdentity {
        FilamentIdentity.resolve(
            colorHex: CLAY_BROWN, spoolColorName: "Clay Brown", material: "PLA", product: "Bambu PLA Wood"
        )
    }

    /// Identity from the mapped spool, quantities from the slice.
    func testMappedRowTakesItsIdentityFromTheSelection() throws {
        let row = try XCTUnwrap(FilamentIdentity.reviewRows(plate, selection: selection).first)
        XCTAssertEqual(row.name, "Clay Brown · Bambu PLA Wood")
        XCTAssertEqual(row.colorHex, CLAY_BROWN)
        XCTAssertEqual(row.grams, 152.1)
        XCTAssertEqual(row.meters, 51.0)
    }

    func testWithoutASelectionThePlateDescribesItself() throws {
        let row = try XCTUnwrap(FilamentIdentity.reviewRows(plate, selection: nil).first)
        XCTAssertEqual(row.name, "PLA")
        XCTAssertEqual(row.colorHex, "#00AE42")
    }

    /// An empty tray (or one inventory has never seen) names nothing, and nothing is not an
    /// improvement on the plate's own words.
    func testASelectionThatNamesNothingDoesNotOverrideThePlate() throws {
        let blank = FilamentIdentity.resolve(colorHex: nil, spoolColorName: nil, material: nil, product: nil)
        let row = try XCTUnwrap(FilamentIdentity.reviewRows(plate, selection: blank).first)
        XCTAssertEqual(row.name, "PLA")
        XCTAssertEqual(row.colorHex, "#00AE42")
    }

    /// `ams_mapping` binds ONE filament to the chosen tray, so the rest stay the slicer's.
    func testOnlyTheMappedRowIsRewritten() {
        let multi = [
            ReviewFilament(slot: 1, type: "PLA", color: "#00AE42", grams: 152.1, meters: 51),
            ReviewFilament(slot: 2, type: "PETG", color: "#000000", grams: 4, meters: 1.2),
        ]
        let rows = FilamentIdentity.reviewRows(multi, selection: selection)
        XCTAssertEqual(rows.map(\.name), ["Clay Brown · Bambu PLA Wood", "PETG"])
        XCTAssertEqual(rows.map(\.colorHex), [CLAY_BROWN, "#000000"])
        XCTAssertEqual(rows.map(\.index), [0, 1])
    }

    func testMappedIndexIsHonoured() {
        let multi = [
            ReviewFilament(slot: 1, type: "PLA", color: "#00AE42", grams: 1, meters: nil),
            ReviewFilament(slot: 2, type: "PETG", color: "#000000", grams: 2, meters: nil),
        ]
        let rows = FilamentIdentity.reviewRows(multi, selection: selection, mappedIndex: 1)
        XCTAssertEqual(rows.map(\.name), ["PLA", "Clay Brown · Bambu PLA Wood"])
    }

    /// A plate that lists no filament still has a chosen spool worth showing — with no quantities,
    /// because nothing measured any.
    func testEmptyPlateListFallsBackToTheSelectionAlone() {
        let rows = FilamentIdentity.reviewRows([], selection: selection)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "Clay Brown · Bambu PLA Wood")
        XCTAssertNil(rows.first?.grams)
        XCTAssertNil(rows.first?.meters)
    }

    func testEmptyPlateListAndNoSelectionRendersNothing() {
        XCTAssertEqual(FilamentIdentity.reviewRows([], selection: nil), [])
        let blank = FilamentIdentity.resolve(colorHex: nil, spoolColorName: nil, material: nil, product: nil)
        XCTAssertEqual(FilamentIdentity.reviewRows([], selection: blank), [])
    }

    /// The row must never lose a swatch it could have shown: a spool with no hex keeps the plate's.
    func testSelectionWithoutAColourKeepsThePlateSwatch() throws {
        let noHex = FilamentIdentity.resolve(
            colorHex: nil, spoolColorName: "Clay Brown", material: "PLA", product: "Bambu PLA Wood"
        )
        let row = try XCTUnwrap(FilamentIdentity.reviewRows(plate, selection: noHex).first)
        XCTAssertEqual(row.colorHex, "#00AE42")
        XCTAssertEqual(row.name, "Clay Brown · Bambu PLA Wood")
    }

    /// Plate colours arrive raw — the row is what the swatch reads, so it normalises them.
    func testPlateColoursAreNormalised() {
        let raw = [ReviewFilament(slot: 1, type: "PLA", color: "00AE42FF", grams: nil, meters: nil)]
        XCTAssertEqual(FilamentIdentity.reviewRows(raw, selection: nil).first?.colorHex, "#00AE42")
        let junk = [ReviewFilament(slot: 1, type: "PLA", color: "#TRANSP", grams: nil, meters: nil)]
        XCTAssertNil(FilamentIdentity.reviewRows(junk, selection: nil).first?.colorHex)
    }

    /// An out-of-range mapping index leaves every row alone rather than trapping.
    func testMappedIndexOutOfRangeIsHarmless() {
        let rows = FilamentIdentity.reviewRows(plate, selection: selection, mappedIndex: 7)
        XCTAssertEqual(rows.map(\.name), ["PLA"])
    }
}

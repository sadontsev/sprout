import XCTest
@testable import Sprout

/// A unit-0 tray ref by default, matching the pre-multi-unit fixtures (global id == local id there).
private func ref(_ localId: Int, _ trayType: String? = nil, _ trayColor: String? = nil, unit unitId: Int = 0) -> AmsTrayRef {
    AmsTrayRef(
        unitId: unitId,
        unitLabel: unitId >= 128 ? "AMS HT" : "AMS \(unitId + 1)",
        localId: localId,
        globalId: AmsTopology.globalTrayId(unitId: unitId, localId: localId),
        trayType: trayType,
        trayColor: trayColor
    )
}

private func preset(_ id: String, _ name: String) -> Preset {
    Preset(id: id, name: name, source: nil)
}

private func spool(
    colorName: String? = nil,
    rgba: String? = nil,
    slicerFilamentName: String? = nil
) -> AssignmentLike.SpoolLike {
    AssignmentLike.SpoolLike(colorName: colorName, rgba: rgba, slicerFilamentName: slicerFilamentName)
}

private let PRESETS: [Preset] = [
    preset("a", "Bambu PLA Basic @BBL A1"),
    preset("b", "Bambu PLA Basic @BBL A1M"),            // wrong machine
    preset("c", "Bambu PETG-CF @BBL A1 0.4 nozzle"),
    preset("d", "Bambu PETG-CF @BBL A1 0.8 nozzle"),    // wrong nozzle
    preset("e", "Bambu Support For PLA @BBL A1"),
    preset("f", "Bambu ABS @BBL A1"),
]

final class FilamentMatchPresetTests: XCTestCase {
    func testMatchesBySlicerNameExactBase() {
        XCTAssertEqual(
            FilamentMatch.preset(in: PRESETS, slicerName: "Bambu PLA Basic", material: "PLA")?.id,
            "a"
        )
    }

    func testMatchesBySlicerNameToTheNozzleVariantWhenNoBaseExists() {
        XCTAssertEqual(
            FilamentMatch.preset(in: PRESETS, slicerName: "Bambu PETG-CF", material: "PETG-CF")?.id,
            "c"
        )
    }

    func testFallsBackToMaterialTypeWhenNoSlicerName() {
        XCTAssertEqual(FilamentMatch.preset(in: PRESETS, slicerName: nil, material: "PLA")?.id, "a")
        XCTAssertEqual(FilamentMatch.preset(in: PRESETS, slicerName: nil, material: "PETG-CF")?.id, "c")
        XCTAssertEqual(FilamentMatch.preset(in: PRESETS, slicerName: nil, material: "ABS")?.id, "f")
    }

    func testNeverReturnsTheWrongMachineOrNozzleVariant() throws {
        let name = try XCTUnwrap(
            FilamentMatch.preset(in: PRESETS, slicerName: "Bambu PLA Basic", material: "PLA")?.name
        )
        XCTAssertFalse(name.contains("A1M"))
        XCTAssertFalse(name.contains("0.8 nozzle"))
    }

    func testReturnsNilForAnUnknownMaterial() {
        XCTAssertNil(FilamentMatch.preset(in: PRESETS, slicerName: nil, material: "UNOBTANIUM"))
    }

    // --- Swift-specific edges -------------------------------------------------------------------

    /// An empty slicer name is "no name", not a base to look up. The JS original leaned on `""` being
    /// falsy; Swift optionals do not give that for free, and the inventory field is blank free text
    /// for an unrecognised spool.
    func testEmptySlicerNameIsTreatedAsAbsent() {
        XCTAssertEqual(FilamentMatch.preset(in: PRESETS, slicerName: "", material: "PLA")?.id, "a")
    }

    func testEmptyMaterialIsTreatedAsAbsent() {
        XCTAssertNil(FilamentMatch.preset(in: PRESETS, slicerName: nil, material: ""))
        XCTAssertNil(FilamentMatch.preset(in: PRESETS, slicerName: "", material: ""))
    }

    /// An unrecognised slicer name must not swallow the match — the material fallback still runs.
    func testUnknownSlicerNameFallsThroughToMaterial() {
        XCTAssertEqual(
            FilamentMatch.preset(in: PRESETS, slicerName: "Polymaker PolyLite", material: "PLA")?.id,
            "a"
        )
    }

    /// The inventory spool's own preset name is authoritative — it beats the tray's material type.
    func testSlicerNameWinsOverMaterialWhenTheyDisagree() {
        XCTAssertEqual(
            FilamentMatch.preset(in: PRESETS, slicerName: "Bambu ABS", material: "PLA")?.id,
            "f"
        )
    }

    /// The material table is keyed uppercase; a tray reporting any other casing must still resolve.
    func testMaterialLookupIsCaseInsensitive() {
        XCTAssertEqual(FilamentMatch.preset(in: PRESETS, slicerName: nil, material: "pla")?.id, "a")
        XCTAssertEqual(FilamentMatch.preset(in: PRESETS, slicerName: nil, material: "Petg-Cf")?.id, "c")
    }

    func testAnEmptyPresetListMatchesNothing() {
        XCTAssertNil(FilamentMatch.preset(in: [], slicerName: "Bambu PLA Basic", material: "PLA"))
    }
}

final class FilamentMatchH2CTokenTests: XCTestCase {
    private let h2cPresets: [Preset] = [
        preset("h1", "Bambu PETG HF @BBL H2C"),
        preset("h2", "Bambu PETG HF @BBL H2C 0.8 nozzle"),  // wrong nozzle
        preset("d1", "Bambu PETG HF @BBL H2D"),             // different machine
    ] + PRESETS

    func testPicksTheH2CPresetNeverTheH2DOrA1One() {
        XCTAssertEqual(
            FilamentMatch.preset(in: h2cPresets, slicerName: nil, material: "PETG", token: "@BBL H2C")?.id,
            "h1"
        )
    }

    func testTheDefaultTokenStillResolvesToTheA1() {
        XCTAssertEqual(FilamentMatch.preset(in: h2cPresets, slicerName: nil, material: "PLA")?.id, "a")
    }

    func testReturnsNilWhenTheMachineHasNoPresetForTheMaterial() {
        XCTAssertNil(
            FilamentMatch.preset(in: h2cPresets, slicerName: nil, material: "ABS", token: "@BBL H2C")
        )
    }

    /// A token no preset carries yields an empty pool rather than a loose prefix match.
    func testAnUnknownTokenMatchesNothing() {
        XCTAssertNil(
            FilamentMatch.preset(in: h2cPresets, slicerName: "Bambu PETG HF", material: "PETG", token: "@BBL X9")
        )
    }
}

final class FilamentMatchLoadedTests: XCTestCase {
    // Real AMS shape: tray 0 support, 1 PETG-CF (gray), 2 PLA (black), 3 empty.
    private let trays: [AmsTrayRef] = [
        ref(0, "PLA-S", "00000000"),
        ref(1, "PETG-CF", "565656FF"),
        ref(2, "PLA", "000000FF"),
        ref(3, nil, nil),
    ]
    private let assigns: [AssignmentLike] = [
        AssignmentLike(
            trayId: 1,
            spool: spool(colorName: "Titan Gray", rgba: "565656FF", slicerFilamentName: "Bambu PETG-CF")
        )
    ]

    func testBuildsOneOptionPerLoadedTraySkippingEmptySlots() {
        let out = FilamentMatch.loaded(trays: trays, assignments: assigns, presets: PRESETS)
        XCTAssertEqual(out.map(\.slot), [0, 1, 2])  // tray 3 empty -> skipped
    }

    func testUsesInventorySlicerNameAndColorNameWhenAvailableElseTheTrayData() throws {
        let out = FilamentMatch.loaded(trays: trays, assignments: assigns, presets: PRESETS)

        let petg = try XCTUnwrap(out.first { $0.slot == 1 })
        XCTAssertEqual(petg.material, "PETG-CF")
        XCTAssertEqual(petg.colorName, "Titan Gray")
        XCTAssertEqual(petg.colorHex, "#565656")  // the alpha byte is stripped
        XCTAssertEqual(petg.preset?.id, "c")

        let pla = try XCTUnwrap(out.first { $0.slot == 2 })
        XCTAssertNil(pla.colorName)               // no inventory -> tray data only
        XCTAssertEqual(pla.preset?.id, "a")       // mapped by material type
    }

    func testFlagsSupportFilament() throws {
        let out = FilamentMatch.loaded(trays: trays, assignments: assigns, presets: PRESETS)
        XCTAssertTrue(try XCTUnwrap(out.first { $0.slot == 0 }).isSupport)
        XCTAssertFalse(try XCTUnwrap(out.first { $0.slot == 1 }).isSupport)
    }

    // --- Swift-specific edges -------------------------------------------------------------------

    /// A tray reporting `""` for its material is an empty slot too — the JS original leaned on that
    /// string being falsy.
    func testAnEmptyTrayTypeStringSkipsTheTray() {
        let out = FilamentMatch.loaded(
            trays: [ref(0, ""), ref(1, "PLA", "000000FF")],
            assignments: [],
            presets: PRESETS
        )
        XCTAssertEqual(out.map(\.slot), [1])
    }

    /// Alpha exactly "00" is the printer's "colour unknown" sentinel, so the inventory spool's colour
    /// is what the user should see — not a fabricated black.
    func testAnUnknownTrayColourFallsBackToTheSpoolColour() throws {
        let out = FilamentMatch.loaded(
            trays: [ref(0, "PLA", "00000000")],
            assignments: [AssignmentLike(trayId: 0, spool: spool(rgba: "FF0000FF"))],
            presets: PRESETS
        )
        XCTAssertEqual(try XCTUnwrap(out.first).colorHex, "#FF0000")
    }

    func testColourIsNilWhenNeitherTrayNorSpoolKnowsIt() throws {
        let out = FilamentMatch.loaded(trays: [ref(0, "PLA", "00000000")], assignments: [], presets: PRESETS)
        XCTAssertNil(try XCTUnwrap(out.first).colorHex)
    }

    /// The tray's own colour outranks the spool's — the AMS reads the filament actually fitted.
    func testTheTrayColourWinsOverTheSpoolColour() throws {
        let out = FilamentMatch.loaded(
            trays: [ref(0, "PLA", "112233FF")],
            assignments: [AssignmentLike(trayId: 0, spool: spool(rgba: "FF0000FF"))],
            presets: PRESETS
        )
        XCTAssertEqual(try XCTUnwrap(out.first).colorHex, "#112233")
    }

    func testSupportDetectionIsCaseInsensitive() {
        let out = FilamentMatch.loaded(
            trays: [ref(0, "pla-s"), ref(1, "PVA"), ref(2, "Support For PLA"), ref(3, "PLA")],
            assignments: [],
            presets: PRESETS
        )
        XCTAssertEqual(out.map(\.isSupport), [true, true, true, false])
    }

    /// `id` is the GLOBAL slot, so a list can key on it across units without collisions.
    func testIdentityIsTheGlobalSlot() {
        let out = FilamentMatch.loaded(
            trays: [ref(0, "PLA"), ref(0, "PLA", nil, unit: 1)],
            assignments: [],
            presets: PRESETS
        )
        XCTAssertEqual(out.map(\.id), [0, 4])
    }

    /// The bridge from the full inventory type has to keep the two ids matching depends on.
    func testTheBridgeFromASlotAssignmentKeepsBothIdsAndTheSpool() {
        let inventorySpool = Spool(
            id: 7,
            material: "PETG-CF",
            colorName: "Titan Gray",
            rgba: "565656FF",
            slicerFilamentName: "Bambu PETG-CF"
        )
        let like = AssignmentLike(SlotAssignment(id: 3, amsId: 1, trayId: 2, spool: inventorySpool))
        XCTAssertEqual(like.trayId, 2)
        XCTAssertEqual(like.amsId, 1)
        XCTAssertEqual(like.spool?.colorName, "Titan Gray")
        XCTAssertEqual(like.spool?.rgba, "565656FF")
        XCTAssertEqual(like.spool?.slicerFilamentName, "Bambu PETG-CF")
    }
}

// Nozzle-size resolution. Fixtures mirror the LIVE H2C set (189 presets, captured 2026-07-19): every
// material ships a bare form; size variants exist only where Bambu tuned one. The convention is
// asymmetric and these two materials ARE the whole spec:
//   Bambu PLA Basic @BBL H2C -> bare + 0.2/0.6/0.8, NO 0.4  (0.4 must resolve to the bare form)
//   Bambu PETG-CF  @BBL H2C  -> bare + 0.4                  (0.4 must resolve to the SUFFIXED one)
final class FilamentMatchNozzleSizeTests: XCTestCase {
    private let presets: [Preset] = [
        preset("pla-bare", "Bambu PLA Basic @BBL H2C"),
        preset("pla-02", "Bambu PLA Basic @BBL H2C 0.2 nozzle"),
        preset("pla-06", "Bambu PLA Basic @BBL H2C 0.6 nozzle"),
        preset("pla-08", "Bambu PLA Basic @BBL H2C 0.8 nozzle"),
        preset("cf-bare", "Bambu PETG-CF @BBL H2C"),
        preset("cf-04", "Bambu PETG-CF @BBL H2C 0.4 nozzle"),
        preset("other-model", "Bambu PLA Basic @BBL A1M 0.6 nozzle"),
    ]

    private func pick(_ name: String, _ nozzle: NozzleSize) -> String? {
        FilamentMatch.preset(in: presets, slicerName: name, material: nil, token: "@BBL H2C", nozzle: nozzle)?.id
    }

    func test04FallsBackToTheBareFormWhenNo04VariantExists() {
        XCTAssertEqual(pick("Bambu PLA Basic", .mm04), "pla-bare")
    }

    func test04PrefersAnExplicit04VariantWhenOneExists() {
        XCTAssertEqual(pick("Bambu PETG-CF", .mm04), "cf-04")
    }

    /// Was impossible before the pool stopped being 0.4-only.
    func testEachSizePicksItsOwnVariant() {
        XCTAssertEqual(pick("Bambu PLA Basic", .mm06), "pla-06")
        XCTAssertEqual(pick("Bambu PLA Basic", .mm02), "pla-02")
        XCTAssertEqual(pick("Bambu PLA Basic", .mm08), "pla-08")
    }

    func testASizeWithNoVariantFallsBackToBareNeverToADifferentSize() {
        XCTAssertEqual(pick("Bambu PETG-CF", .mm06), "cf-bare")
        XCTAssertNotEqual(pick("Bambu PLA Basic", .mm04), "pla-06")
    }

    func testDefaultsTo04WhenTheCallerOmitsTheSize() {
        XCTAssertEqual(
            FilamentMatch.preset(in: presets, slicerName: "Bambu PLA Basic", material: nil, token: "@BBL H2C")?.id,
            "pla-bare"
        )
    }

    func testNeverLeaksAnotherPrinterModelWhateverTheSize() {
        XCTAssertNil(
            FilamentMatch.preset(
                in: presets, slicerName: "Bambu PLA Basic", material: nil, token: "@BBL A1", nozzle: .mm06
            )
        )
    }

    func testCatalogResolvesPerSizeAndKeepsCuratedOrder() {
        // PLA Basic before PETG-CF, each at its best match.
        XCTAssertEqual(
            FilamentMatch.catalog(in: presets, token: "@BBL H2C", nozzle: .mm06).map(\.id),
            ["pla-06", "cf-bare"]
        )
        XCTAssertEqual(
            FilamentMatch.catalog(in: presets, token: "@BBL H2C", nozzle: .mm04).map(\.id),
            ["pla-bare", "cf-04"]
        )
    }

    // --- Swift-specific edges -------------------------------------------------------------------

    func testCatalogDefaultsTo04() {
        XCTAssertEqual(FilamentMatch.catalog(in: presets, token: "@BBL H2C").map(\.id), ["pla-bare", "cf-04"])
    }

    /// "@BBL A1" is a prefix of "@BBL A1M", so a sloppy filter would hand back the A1 Mini preset.
    func testCatalogIsEmptyWhenTheMachineHasNoPresets() {
        XCTAssertTrue(FilamentMatch.catalog(in: presets, token: "@BBL A1").isEmpty)
        XCTAssertTrue(FilamentMatch.catalog(in: [], token: "@BBL H2C").isEmpty)
    }

    /// The curated order is the order the wizard shows, so it is part of the contract.
    func testCatalogMaterialsOrderIsStable() {
        XCTAssertEqual(FilamentMatch.catalogMaterials, [
            "Bambu PLA Basic", "Bambu PLA Matte", "Bambu PETG HF", "Bambu PETG-CF",
            "Bambu ABS", "Bambu ASA", "Bambu TPU 95A HF", "Bambu Support For PLA",
        ])
    }
}

final class FilamentMatchLoadedNozzleSizeTests: XCTestCase {
    func testThreadsTheNozzleThroughToEachTraysPreset() {
        let presets: [Preset] = [
            preset("bare", "Bambu PETG HF @BBL H2C"),
            preset("six", "Bambu PETG HF @BBL H2C 0.6 nozzle"),
        ]
        let trays = [ref(0, "PETG", "000000FF")]
        XCTAssertEqual(
            FilamentMatch.loaded(
                trays: trays, assignments: [], presets: presets, token: "@BBL H2C", nozzle: .mm06
            ).first?.preset?.id,
            "six"
        )
        XCTAssertEqual(
            FilamentMatch.loaded(
                trays: trays, assignments: [], presets: presets, token: "@BBL H2C", nozzle: .mm04
            ).first?.preset?.id,
            "bare"
        )
    }
}

final class FilamentMatchMultiUnitTests: XCTestCase {
    private let presets: [Preset] = [
        preset("petg", "Bambu PETG-CF @BBL H2C"),
        preset("pla", "Bambu PLA Basic @BBL H2C"),
    ]
    // Two AMS 2 Pro units + an HT, as fitted. Each unit has a local tray 0 — they must not collide.
    private let trays: [AmsTrayRef] = [
        ref(0, "PETG-CF", "565656FF", unit: 0),
        ref(0, "PLA", "000000FF", unit: 1),
        ref(0, "PETG-CF", "FFFFFFFF", unit: 128),
    ]

    private func loaded(_ assignments: [AssignmentLike]) -> [LoadedFilament] {
        FilamentMatch.loaded(
            trays: trays, assignments: assignments, presets: presets, token: "@BBL H2C", nozzle: .mm04
        )
    }

    func testEmitsGlobalTrayIdsSoSlotsStayAddressableAcrossUnits() {
        let out = loaded([])
        XCTAssertEqual(out.map(\.slot), [0, 4, 128])
        XCTAssertEqual(out.map(\.unitLabel), ["AMS 1", "AMS 2", "AMS HT"])
        XCTAssertTrue(out.allSatisfy { $0.localId == 0 })  // all local 0 — the collision case
    }

    func testBindsAnInventorySpoolToTheRightUnitNotMerelyTheRightTrayNumber() {
        // Matching on the tray id alone gave AMS 2 and the HT the AMS 1 spool: wrong brand, wrong
        // colour name, and a wrong slicer preset that then drove the slice.
        let out = loaded([
            AssignmentLike(trayId: 0, amsId: 0, spool: spool(colorName: "Titan Gray", slicerFilamentName: "Bambu PETG-CF")),
            AssignmentLike(trayId: 0, amsId: 1, spool: spool(colorName: "Jet Black", slicerFilamentName: "Bambu PLA Basic")),
        ])
        XCTAssertEqual(out[0].colorName, "Titan Gray")
        XCTAssertEqual(out[1].colorName, "Jet Black")
        XCTAssertNil(out[2].colorName)  // the HT has no assignment — it must not inherit one
    }

    /// Each unit's spool also has to drive that unit's preset, not just its label.
    func testEachUnitGetsItsOwnSpoolsPreset() {
        let out = loaded([
            AssignmentLike(trayId: 0, amsId: 0, spool: spool(slicerFilamentName: "Bambu PETG-CF")),
            AssignmentLike(trayId: 0, amsId: 1, spool: spool(slicerFilamentName: "Bambu PLA Basic")),
        ])
        XCTAssertEqual(out.map { $0.preset?.id }, ["petg", "pla", "petg"] as [String?])
    }

    func testStillMatchesALegacyAssignmentThatCarriesNoAmsId() {
        XCTAssertEqual(loaded([AssignmentLike(trayId: 0, spool: spool(colorName: "Legacy"))])[0].colorName, "Legacy")
    }

    func testPrefersAnExactUnitMatchOverALegacyUnitLessOne() {
        let out = loaded([
            AssignmentLike(trayId: 0, spool: spool(colorName: "Legacy")),
            AssignmentLike(trayId: 0, amsId: 1, spool: spool(colorName: "Exact")),
        ])
        XCTAssertEqual(out[1].colorName, "Exact")
    }
}

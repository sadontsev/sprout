import XCTest
@testable import Sprout

final class PrinterProfileTests: XCTestCase {

    /// A printer record carrying only the two fields the profile lookup reads.
    private func rec(_ model: String, nozzles: Int? = nil) -> Printer {
        Printer(id: 1, name: "Printer", model: model, nozzleCount: nozzles)
    }

    private var a1: PrinterProfile { PrinterProfile.forPrinter(rec("A1", nozzles: 1)) }
    private var h2c: PrinterProfile { PrinterProfile.forPrinter(rec("H2C", nozzles: 2)) }

    // MARK: - Known models

    func testA1ProfileTokenPresetBaseAmsLiteSingleNozzle() {
        let p = a1
        XCTAssertEqual(p.presetToken, "@BBL A1")
        XCTAssertEqual(p.printerPresetBase, "Bambu Lab A1")
        XCTAssertEqual(p.amsLabel, "AMS Lite")
        XCTAssertFalse(p.dualNozzle)
        XCTAssertEqual(p.bedTypes.first?.id, "Textured PEI Plate")  // default plate first
    }

    func testA1BedTypesAndPlate() {
        let p = a1
        XCTAssertEqual(
            p.bedTypes.map(\.id),
            ["Textured PEI Plate", "Smooth PEI Plate", "Cool Plate", "Engineering Plate"]
        )
        XCTAssertEqual(p.bedTypes.map(\.label), ["Textured PEI", "Smooth PEI", "Cool Plate", "Engineering"])
        XCTAssertEqual(p.plate, PlateSize(w: 256, d: 256))
    }

    func testH2CProfileTokenDualNozzleAms2ProHighTempPlate() {
        let p = h2c
        XCTAssertEqual(p.presetToken, "@BBL H2C")
        XCTAssertEqual(p.printerPresetBase, "Bambu Lab H2C")
        XCTAssertEqual(p.amsLabel, "AMS 2 Pro")
        XCTAssertTrue(p.dualNozzle)
        XCTAssertTrue(p.bedTypes.map(\.id).contains("High Temp Plate"))
    }

    func testH2CSwapsTheCoolPlateForHighTempAndHasADeeperBed() {
        let p = h2c
        XCTAssertEqual(
            p.bedTypes.map(\.id),
            ["Textured PEI Plate", "Smooth PEI Plate", "High Temp Plate", "Engineering Plate"]
        )
        XCTAssertFalse(p.bedTypes.map(\.id).contains("Cool Plate"))
        XCTAssertEqual(p.plate, PlateSize(w: 350, d: 320))
    }

    func testCameraHintsUseTypographicApostrophes() {
        // Exact copy, including U+2019 — an ASCII apostrophe here is a visible regression.
        XCTAssertEqual(
            a1.cameraHint,
            "The A1\u{2019}s camera is on-demand and can be slow — give it a moment and tap Retry."
        )
        XCTAssertEqual(
            h2c.cameraHint,
            "If this persists, enable LAN Mode Liveview in the printer\u{2019}s settings screen (Settings → General)."
        )
    }

    // MARK: - Unknown models

    func testUnknownModelDegradesToGenericProfileNotToA1Behavior() {
        let p = PrinterProfile.forPrinter(rec("X9", nozzles: 2))
        XCTAssertEqual(p.presetToken, "@BBL X9")
        XCTAssertEqual(p.printerPresetBase, "Bambu Lab X9")
        XCTAssertTrue(p.dualNozzle)
        XCTAssertNotEqual(p, a1)
    }

    func testUnknownModelUsesGenericAmsLabelPlatesAndCameraHint() {
        let p = PrinterProfile.forPrinter(rec("X9", nozzles: 2))
        XCTAssertEqual(p.amsLabel, "AMS")
        XCTAssertEqual(p.bedTypes.map(\.id), a1.bedTypes.map(\.id))
        XCTAssertEqual(p.plate, PlateSize(w: 256, d: 256))
        XCTAssertEqual(p.cameraHint, "Give the camera a moment and tap Retry. Make sure the printer is powered on.")
    }

    func testUnknownModelWithoutANozzleCountAssumesSingleNozzle() {
        XCTAssertFalse(PrinterProfile.forPrinter(rec("X9")).dualNozzle)
        XCTAssertFalse(PrinterProfile.forPrinter(rec("X9", nozzles: 1)).dualNozzle)
        XCTAssertFalse(PrinterProfile.forPrinter(rec("X9", nozzles: 0)).dualNozzle)
    }

    func testNozzleCountAtTheIntegerExtremes() {
        // The comparison is a plain `> 1`; nothing here may trap or wrap.
        XCTAssertTrue(PrinterProfile.forPrinter(rec("X9", nozzles: .max)).dualNozzle)
        XCTAssertFalse(PrinterProfile.forPrinter(rec("X9", nozzles: .min)).dualNozzle)
        XCTAssertFalse(PrinterProfile.forPrinter(rec("X9", nozzles: -3)).dualNozzle)
    }

    func testEmptyModelIsNotTreatedAsMissingAndYieldsAnEmptyGenericToken() {
        // Only a nil RECORD falls back to the A1; a record whose model is blank is still a record.
        let p = PrinterProfile.forPrinter(rec("", nozzles: 1))
        XCTAssertEqual(p.presetToken, "@BBL ")
        XCTAssertEqual(p.printerPresetBase, "Bambu Lab ")
        XCTAssertEqual(p.amsLabel, "AMS")
    }

    func testWhitespaceOnlyModelTrimsToTheEmptyGenericProfile() {
        let p = PrinterProfile.forPrinter(rec("  \n ", nozzles: 1))
        XCTAssertEqual(p.presetToken, "@BBL ")
        XCTAssertEqual(p.amsLabel, "AMS")
    }

    // MARK: - Nil record

    func testNilPrinterFallsBackToTheA1() {
        XCTAssertEqual(PrinterProfile.forPrinter(nil).presetToken, "@BBL A1")
        XCTAssertEqual(PrinterProfile.forPrinter(nil).amsLabel, "AMS Lite")
        XCTAssertEqual(PrinterProfile.forPrinter(nil), a1)
    }

    // MARK: - Model normalisation

    func testModelLookupIsCaseInsensitive() {
        XCTAssertEqual(PrinterProfile.forPrinter(rec("a1", nozzles: 1)), a1)
        XCTAssertEqual(PrinterProfile.forPrinter(rec("h2c", nozzles: 2)), h2c)
        XCTAssertEqual(PrinterProfile.forPrinter(rec("h2C", nozzles: 2)), h2c)
    }

    func testModelIsTrimmedBeforeLookup() {
        XCTAssertEqual(PrinterProfile.forPrinter(rec("  A1  ", nozzles: 1)), a1)
        XCTAssertEqual(PrinterProfile.forPrinter(rec("\tH2C\n", nozzles: 2)), h2c)
    }

    func testGenericTokenKeepsTheModelsOwnCasingButNotItsWhitespace() {
        // The table lookup upper-cases; the derived preset name must NOT — BambuStudio's preset
        // names are case-sensitive.
        let p = PrinterProfile.forPrinter(rec("  x9 ", nozzles: 1))
        XCTAssertEqual(p.presetToken, "@BBL x9")
        XCTAssertEqual(p.printerPresetBase, "Bambu Lab x9")
    }

    // MARK: - slicedFor guard (wrong-machine G-code)

    func testExactModelAndNozzleSuffixedVariantsMatch() {
        XCTAssertTrue(a1.matchesSlicedFor("Bambu Lab A1"))
        XCTAssertTrue(a1.matchesSlicedFor("Bambu Lab A1 0.4 nozzle"))
        XCTAssertTrue(h2c.matchesSlicedFor("Bambu Lab H2C"))
        XCTAssertTrue(h2c.matchesSlicedFor("Bambu Lab H2C 0.6 nozzle"))
    }

    func testOtherMachinesAreRejectedIncludingTheA1MiniTrap() {
        XCTAssertFalse(h2c.matchesSlicedFor("Bambu Lab A1"))
        XCTAssertFalse(a1.matchesSlicedFor("Bambu Lab H2C"))
        XCTAssertFalse(a1.matchesSlicedFor("Bambu Lab A1 mini"))
    }

    func testALongerModelNameSharingThePrefixIsRejected() {
        // The suffix rule accepts " 0." only, so nothing else may ride in on the prefix.
        XCTAssertFalse(a1.matchesSlicedFor("Bambu Lab A10"))
        XCTAssertFalse(a1.matchesSlicedFor("Bambu Lab A1M"))
        XCTAssertFalse(a1.matchesSlicedFor("Bambu Lab A1 Combo"))
    }

    func testUnknownOrEmptyEmbeddedPrinterIsAllowed() {
        XCTAssertTrue(h2c.matchesSlicedFor(nil))
        XCTAssertTrue(h2c.matchesSlicedFor(""))
        XCTAssertTrue(a1.matchesSlicedFor(nil))
        XCTAssertTrue(a1.matchesSlicedFor("   \n"))
    }

    func testEmbeddedNameIsMatchedCaseInsensitivelyAndAfterTrimming() {
        XCTAssertTrue(a1.matchesSlicedFor("bambu lab a1"))
        XCTAssertTrue(a1.matchesSlicedFor("  BAMBU LAB A1  "))
        XCTAssertTrue(h2c.matchesSlicedFor("bambu lab h2c 0.8 NOZZLE"))
    }

    func testEmbeddedNameWithoutTheVendorPrefixStillMatches() {
        // Some slicers write the bare model.
        XCTAssertTrue(a1.matchesSlicedFor("A1"))
        XCTAssertTrue(a1.matchesSlicedFor("A1 0.4 nozzle"))
        XCTAssertFalse(a1.matchesSlicedFor("H2C"))
    }

    func testARepeatedVendorPrefixIsNotCollapsedIntoAMatch() {
        // Only the first "BAMBU LAB " is stripped, so this stays a non-match instead of becoming
        // a bare "A1".
        XCTAssertFalse(a1.matchesSlicedFor("Bambu Lab Bambu Lab A1"))
    }

    func testTheGuardWorksForAGenericProfileToo() {
        let x9 = PrinterProfile.forPrinter(rec("X9", nozzles: 1))
        XCTAssertTrue(x9.matchesSlicedFor("Bambu Lab X9"))
        XCTAssertTrue(x9.matchesSlicedFor("Bambu Lab X9 0.4 nozzle"))
        XCTAssertFalse(x9.matchesSlicedFor("Bambu Lab A1"))
        XCTAssertFalse(x9.matchesSlicedFor("Bambu Lab X90"))
    }

    func testCaseFoldingInTheGuardIsLocaleIndependent() {
        // A dotted/dotless-i locale must not change the answer: `uppercased()` (no locale) maps
        // "mini" to "MINI" everywhere, whereas a Turkish-locale uppercase would yield "MİNİ".
        let mini = PrinterProfile.forPrinter(rec("mini", nozzles: 1))
        XCTAssertEqual(mini.printerPresetBase, "Bambu Lab mini")
        XCTAssertTrue(mini.matchesSlicedFor("Bambu Lab mini"))
        XCTAssertTrue(mini.matchesSlicedFor("BAMBU LAB MINI"))
    }
}

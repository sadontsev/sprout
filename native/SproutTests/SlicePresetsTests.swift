import XCTest
@testable import Sprout

/// Flattening `GET /slicer/presets` into the four lists a slice needs.
///
/// This was `WizardPresets`, private to an iOS-only view. The tests exist because macOS now builds the
/// same value, and the two must not drift — but also because the tri-state below is easy to
/// accidentally collapse into a `Bool` and the collapse is invisible until a network error shows a
/// user the wrong explanation.
final class SlicePresetsTests: XCTestCase {

    private func preset(_ id: String, _ name: String) -> Preset { Preset(id: id, name: name) }

    private func response(printer: [Preset] = [], process: [Preset] = [],
                         filament: [Preset] = []) -> PresetsResponse {
        PresetsResponse(standard: PresetsResponse.Group(printer: printer,
                                                       process: process,
                                                       filament: filament))
    }

    // MARK: - The machine preset and its two fallbacks

    /// Tier 1: the exact nozzle variant is what you actually want.
    func testTheExactNozzleVariantWins() {
        let stock = [preset("1", "Bambu Lab H2C"),
                     preset("2", "Bambu Lab H2C 0.4 nozzle"),
                     preset("3", "Bambu Lab H2C 0.6 nozzle")]
        XCTAssertEqual(
            PresetSelect.pickPrinterPreset(stock, base: "Bambu Lab H2C", nozzle: .mm06)?.name,
            "Bambu Lab H2C 0.6 nozzle"
        )
    }

    /// Tier 2: 0.4 is the only variant every A1/H2 profile set is guaranteed to ship, so an unusual
    /// nozzle lands there rather than nowhere.
    func testAnUnshippedNozzleFallsBackToTheZeroFourName() {
        let stock = [preset("1", "Bambu Lab H2C"), preset("2", "Bambu Lab H2C 0.4 nozzle")]
        XCTAssertEqual(
            PresetSelect.pickPrinterPreset(stock, base: "Bambu Lab H2C", nozzle: .mm08)?.name,
            "Bambu Lab H2C 0.4 nozzle"
        )
    }

    /// Tier 3: a profile set that does not split by nozzle at all.
    func testABareBaseNameIsTheLastResort() {
        let stock = [preset("1", "Bambu Lab H2C")]
        XCTAssertEqual(
            PresetSelect.pickPrinterPreset(stock, base: "Bambu Lab H2C", nozzle: .mm06)?.name,
            "Bambu Lab H2C"
        )
    }

    /// Nil rather than a guess. `SlicePresets.canSlice` reads this, and a slice with no machine preset
    /// is a slice for no machine.
    func testNoMatchAtAllIsNilRatherThanTheFirstRow() {
        let stock = [preset("1", "Creality K2 Pro"), preset("2", "Bambu Lab A1 0.4 nozzle")]
        XCTAssertNil(PresetSelect.pickPrinterPreset(stock, base: "Bambu Lab H2C", nozzle: .mm04))
        XCTAssertNil(PresetSelect.pickPrinterPreset([], base: "Bambu Lab H2C", nozzle: .mm04))
    }

    /// A 0.6 request must never land on the 0.8 row just because both are suffixed.
    func testOneNozzleNeverPicksAnother() {
        let stock = [preset("1", "Bambu Lab H2C 0.8 nozzle")]
        XCTAssertNil(PresetSelect.pickPrinterPreset(stock, base: "Bambu Lab H2C", nozzle: .mm06),
                     "0.8 is not a fallback for 0.6 — only the 0.4 name and the bare base are")
    }

    // MARK: - The tri-state

    /// The whole reason this type wraps `ProcessPresets` instead of widening it: `false` and `nil` are
    /// different answers and the UI must say different things.
    func testAFailedFetchIsNotTheSameAsNoSupportProfiles() {
        // Answered, none provisioned → false, so the provisioning notice is correct.
        let answered = SlicePresets.build(
            from: response(printer: [preset("1", "Bambu Lab H2C 0.4 nozzle")],
                          process: [preset("q", "0.20mm Standard @BBL H2C")]),
            printerPresetBase: "Bambu Lab H2C", token: "@BBL H2C", nozzle: .mm04
        )
        XCTAssertEqual(answered.hasSupportProfile, false)

        // Never asked / the ask failed → nil, and the caller must show NOTHING rather than blame the
        // user's preset library for a network error.
        XCTAssertNil(SlicePresets().hasSupportProfile)
    }

    // MARK: - canSlice

    func testTheMachinePresetIsWhatMakesItSliceable() {
        XCTAssertFalse(SlicePresets().canSlice, "no machine preset, no slice")
        XCTAssertTrue(SlicePresets(printer: preset("1", "Bambu Lab H2C 0.4 nozzle")).canSlice)
    }

    /// Quality is not required — it has a sensible default. Supports are optional by nature.
    func testQualityAndSupportsAreNotRequired() {
        let p = SlicePresets(printer: preset("1", "Bambu Lab H2C 0.4 nozzle"),
                             qualities: [], supportByBase: [:], hasSupportProfile: false)
        XCTAssertTrue(p.canSlice)
    }

    // MARK: - Build wiring

    /// `allFilaments` is the UNFILTERED set, because `FilamentMatch.loaded` does its own matching and
    /// needs everything to do it. `catalog` is the machine-matched subset. Handing `loaded` the
    /// catalog would narrow it twice.
    func testBuildKeepsBothTheFullFilamentListAndTheMatchedCatalog() {
        let filaments = [preset("f1", "Bambu PLA Basic @BBL H2C"),
                         preset("f2", "Generic PETG @BBL A1")]
        let p = SlicePresets.build(
            from: response(printer: [preset("1", "Bambu Lab H2C 0.4 nozzle")], filament: filaments),
            printerPresetBase: "Bambu Lab H2C", token: "@BBL H2C", nozzle: .mm04
        )
        XCTAssertEqual(p.allFilaments.count, 2, "the full set survives")
        XCTAssertLessThanOrEqual(p.catalog.count, p.allFilaments.count,
                                 "the catalog is a machine-matched subset, never larger")
    }

    /// An empty response is a valid response and must not crash or half-populate.
    func testAnEmptyResponseFlattensToAnEmptyBundle() {
        let p = SlicePresets.build(from: response(), printerPresetBase: "Bambu Lab H2C",
                                   token: "@BBL H2C", nozzle: .mm04)
        XCTAssertNil(p.printer)
        XCTAssertFalse(p.canSlice)
        XCTAssertTrue(p.qualities.isEmpty)
        XCTAssertTrue(p.allFilaments.isEmpty)
    }
}

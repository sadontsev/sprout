import XCTest
@testable import Sprout

final class PresetSelectTests: XCTestCase {

    /// A realistic slice of a /slicer/presets response (names verified against the live backend).
    private let resp = PresetsResponse(
        standard: .init(process: [
            Preset(id: "1", name: "0.20mm Standard @BBL A1"),
            Preset(id: "2", name: "0.20mm Strength @BBL A1"),
            Preset(id: "3", name: "0.08mm Extra Fine @BBL A1"),
            Preset(id: "4", name: "0.06mm Fine @BBL A1 0.2 nozzle"),      // wrong nozzle
            Preset(id: "5", name: "0.30mm Standard @BBL A1 0.6 nozzle"),  // wrong nozzle
            Preset(id: "6", name: "0.32mm Optimal @BBL A1 0.8 nozzle"),   // wrong nozzle
            Preset(id: "7", name: "0.20mm Standard @BBL A1M"),            // A1 Mini, not our machine
            Preset(id: "8", name: "0.20mm Standard @BBL P1P"),            // other printer
        ]),
        // The user's own custom support profile.
        local: .init(process: [Preset(id: "100", name: "0.20mm Standard + Supports @BBL A1")]),
        cloud: .init(),
        orcaCloud: .init()
    )

    private func names(_ presets: [Preset]) -> [String] { presets.map(\.name) }

    // MARK: - selectA1Process

    func testKeepsOnlyA1DefaultNozzleBaseQualities() {
        let qualities = PresetSelect.selectA1Process(resp).qualities
        XCTAssertEqual(names(qualities), [
            "0.20mm Standard @BBL A1",
            "0.20mm Strength @BBL A1",
            "0.08mm Extra Fine @BBL A1",
        ])
        // The twin is excluded from the grid.
        XCTAssertFalse(names(qualities).contains { $0.lowercased().contains("+ supports") })
        XCTAssertFalse(names(qualities).contains { $0.contains("0.2 nozzle") || $0.contains("0.6 nozzle") || $0.contains("0.8 nozzle") })
        XCTAssertFalse(names(qualities).contains { $0.contains("A1M") || $0.contains("P1P") })
    }

    func testPairsEachBaseQualityToItsSupportTwinFromTheLocalGroup() {
        let r = PresetSelect.selectA1Process(resp)
        XCTAssertTrue(r.hasSupportProfile)
        XCTAssertEqual(r.supportByBase["0.20mm Standard @BBL A1"]?.id, "100") // the local twin
        XCTAssertNil(r.supportByBase["0.20mm Strength @BBL A1"])              // no twin for this one
    }

    func testReportsNoSupportProfileWhenNoneExist() {
        let noSupport = PresetsResponse(
            standard: .init(process: [Preset(id: "1", name: "0.20mm Standard @BBL A1")])
        )
        let r = PresetSelect.selectA1Process(noSupport)
        XCTAssertFalse(r.hasSupportProfile)
        XCTAssertTrue(r.supportByBase.isEmpty)
    }

    func testDedupesAProfileEchoedIntoMultipleGroupsById() {
        let dup = PresetsResponse(
            standard: .init(process: [Preset(id: "x", name: "0.20mm Standard @BBL A1")]),
            cloud: .init(process: [Preset(id: "x", name: "0.20mm Standard @BBL A1")])
        )
        XCTAssertEqual(PresetSelect.selectA1Process(dup).qualities.count, 1)
    }

    func testIsSafeOnEmptyOrMissingInput() {
        XCTAssertEqual(PresetSelect.selectA1Process(nil), ProcessPresets())
        XCTAssertEqual(PresetSelect.selectA1Process(PresetsResponse()), ProcessPresets())
        XCTAssertEqual(PresetSelect.selectA1Process(PresetsResponse(standard: .init(process: []))), ProcessPresets())
    }

    // MARK: - supportTwinName

    func testSupportTwinNameInsertsBeforeTheModelToken() {
        XCTAssertEqual(
            PresetSelect.supportTwinName("0.20mm Standard @BBL A1"),
            "0.20mm Standard + Supports @BBL A1"
        )
        XCTAssertEqual(PresetSelect.supportTwinName("Custom"), "Custom + Supports")
    }

    func testSupportTwinNameWorksForOtherModelTokens() {
        XCTAssertEqual(
            PresetSelect.supportTwinName("0.20mm Standard @BBL H2C", token: "@BBL H2C"),
            "0.20mm Standard + Supports @BBL H2C"
        )
    }

    func testSupportTwinNameRewritesOnlyTheFirstTokenOccurrence() {
        // Replacing every occurrence would emit two "+ Supports" markers and the name would then
        // never match the twin the provisioning script actually created.
        XCTAssertEqual(
            PresetSelect.supportTwinName("@BBL A1 copy @BBL A1", token: "@BBL A1"),
            "@BBL A1 copy + Supports @BBL A1"
        )
    }

    // MARK: - selectProcess with the H2C token (names verified against the live backend)

    private let h2c = PresetsResponse(standard: .init(process: [
        Preset(id: "h1", name: "0.20mm Standard @BBL H2C"),
        Preset(id: "h2", name: "0.08mm High Quality @BBL H2C"),
        Preset(id: "h3", name: "0.10mm Standard @BBL H2C 0.2 nozzle"), // wrong nozzle
        Preset(id: "d1", name: "0.20mm Standard @BBL H2D"),            // different machine
        Preset(id: "d2", name: "0.08mm Extra Fine @BBL H2DP"),         // H2D Pro must not leak in
        Preset(id: "a1", name: "0.20mm Standard @BBL A1"),             // different machine
    ]))

    func testKeepsOnlyH2CDefaultNozzlePresets() {
        let r = PresetSelect.selectProcess(h2c, token: "@BBL H2C")
        XCTAssertEqual(names(r.qualities), ["0.20mm Standard @BBL H2C", "0.08mm High Quality @BBL H2C"])
    }

    func testTheA1TokenDoesNotPickUpH2CPresets() {
        let r = PresetSelect.selectProcess(h2c, token: "@BBL A1")
        XCTAssertEqual(names(r.qualities), ["0.20mm Standard @BBL A1"])
    }

    func testTokenIsMatchedLiterallyNotAsARegexPattern() {
        // '.' in a model token must not act as a wildcard, or a neighbouring model would match.
        let odd = PresetsResponse(standard: .init(process: [
            Preset(id: "1", name: "0.20mm Standard @BBL X.Y"),
            Preset(id: "2", name: "0.20mm Standard @BBL XZY"),
        ]))
        XCTAssertEqual(names(PresetSelect.selectProcess(odd, token: "@BBL X.Y").qualities), ["0.20mm Standard @BBL X.Y"])
    }

    func testNonASCIIPresetNamesAreMatchedWithoutRangeMisalignment() {
        // NSRegularExpression works in UTF-16 offsets; a multi-byte or surrogate-pair name must not
        // shift the match window.
        let unicode = PresetsResponse(standard: .init(process: [
            Preset(id: "1", name: "0.20mm Стандарт @BBL A1"),
            Preset(id: "2", name: "0.20mm 🧵 Fine @BBL A1"),
        ]))
        XCTAssertEqual(PresetSelect.selectA1Process(unicode).qualities.count, 2)
    }

    // MARK: - pickDefaultQuality

    func testPickDefaultQualityPrefersStandard020() {
        let list = [
            Preset(id: "a", name: "0.08mm Fine @BBL A1"),
            Preset(id: "b", name: "0.20mm Standard @BBL A1"),
            Preset(id: "c", name: "0.20mm Strength @BBL A1"),
        ]
        XCTAssertEqual(PresetSelect.pickDefaultQuality(list)?.name, "0.20mm Standard @BBL A1")
    }

    func testPickDefaultQualityFallsBackToAny020ThenTheFirst() {
        XCTAssertEqual(
            PresetSelect.pickDefaultQuality([
                Preset(id: "a", name: "0.08mm Fine @BBL A1"),
                Preset(id: "b", name: "0.20mm Strength @BBL A1"),
            ])?.name,
            "0.20mm Strength @BBL A1"
        )
        XCTAssertEqual(
            PresetSelect.pickDefaultQuality([Preset(id: "a", name: "0.08mm Fine @BBL A1")])?.name,
            "0.08mm Fine @BBL A1"
        )
        XCTAssertNil(PresetSelect.pickDefaultQuality([]))
    }

    // MARK: - Nozzle variants

    private let h2 = PresetsResponse(standard: .init(process: [
        Preset(id: "1", name: "0.20mm Standard @BBL H2C"),
        Preset(id: "2", name: "0.08mm High Quality @BBL H2C"),
        Preset(id: "3", name: "0.30mm Standard @BBL H2C 0.6 nozzle"),
        Preset(id: "4", name: "0.36mm Standard @BBL H2C 0.6 nozzle"),
        Preset(id: "5", name: "0.10mm Standard @BBL H2C 0.2 nozzle"),
        Preset(id: "6", name: "0.30mm Standard @BBL H2D 0.6 nozzle"), // other machine, same suffix
    ]))

    func testNozzle06SelectsOnlyThatVariantFamily() {
        let r = PresetSelect.selectProcess(h2, token: "@BBL H2C", nozzle: .mm06)
        XCTAssertEqual(names(r.qualities), [
            "0.30mm Standard @BBL H2C 0.6 nozzle",
            "0.36mm Standard @BBL H2C 0.6 nozzle",
        ])
    }

    func testDefaultNozzleKeepsTheUnsuffixedFamilyOnly() {
        let r = PresetSelect.selectProcess(h2, token: "@BBL H2C")
        XCTAssertEqual(names(r.qualities), ["0.20mm Standard @BBL H2C", "0.08mm High Quality @BBL H2C"])
    }

    func testPrinterPresetNameForBuildsTheStockVariantName() {
        XCTAssertEqual(PresetSelect.printerPresetNameFor("Bambu Lab H2C", nozzle: .mm06), "Bambu Lab H2C 0.6 nozzle")
    }

    func testMountedNozzlesReadsLiveStatusDedupedWithGarbageDropped() {
        // H2C: 0.6 on the left, 0.4 on the right.
        XCTAssertEqual(
            PresetSelect.mountedNozzles(PrinterStatus(nozzles: [
                NozzleInfo(nozzleDiameter: "0.6"),
                NozzleInfo(nozzleDiameter: "0.4"),
            ])),
            [.mm06, .mm04]
        )
        XCTAssertEqual(
            PresetSelect.mountedNozzles(PrinterStatus(nozzles: [
                NozzleInfo(nozzleDiameter: "0.4"),
                NozzleInfo(nozzleDiameter: "0.4"),
                NozzleInfo(nozzleDiameter: "x"),
                NozzleInfo(nozzleDiameter: nil),
                NozzleInfo(nozzleDiameter: "0.40"), // not a stock family name
            ])),
            [.mm04]
        )
        XCTAssertEqual(PresetSelect.mountedNozzles(nil), [])
        XCTAssertEqual(PresetSelect.mountedNozzles(PrinterStatus()), [])
        XCTAssertEqual(PresetSelect.mountedNozzles(PrinterStatus(nozzles: [])), [])
    }

    func testDefaultNozzlePrefers04ThenFirstMountedThen04() {
        XCTAssertEqual(PresetSelect.defaultNozzle([.mm06, .mm04]), .mm04)
        XCTAssertEqual(PresetSelect.defaultNozzle([.mm06, .mm02]), .mm06)
        XCTAssertEqual(PresetSelect.defaultNozzle([]), .mm04)
    }

    func testNozzleSizeRawValuesMatchThePresetNamingExactly() {
        // The raw values are spliced straight into preset names, so a cosmetic rename here would
        // silently stop matching every variant family.
        XCTAssertEqual(NozzleSize.allCases.map(\.rawValue), ["0.2", "0.4", "0.6", "0.8"])
    }

    // MARK: - isA1

    func testIsA1MatchesA1ButNotA1MiniOrA1M() {
        XCTAssertTrue(PresetSelect.isA1("0.20mm Standard @BBL A1"))
        XCTAssertFalse(PresetSelect.isA1("0.20mm Standard @BBL A1M"))
        XCTAssertFalse(PresetSelect.isA1("Bambu A1 mini something"))
        XCTAssertFalse(PresetSelect.isA1("Bambu A1 MINI something"))
        XCTAssertFalse(PresetSelect.isA1("0.20mm Standard @BBL P1S"))
    }
}

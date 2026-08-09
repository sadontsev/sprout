import XCTest
@testable import Sprout

// MARK: - Fixtures

/// Decodes a `LooseNumber` from a raw JSON fragment, so the string forms the WebSocket really sends
/// ("344", "44.7") go through the actual decoder instead of being hand-built as numbers.
private func wsNumber(_ fragment: String, file: StaticString = #filePath, line: UInt = #line) -> LooseNumber {
    do {
        return try JSONDecoder().decode([LooseNumber].self, from: Data("[\(fragment)]".utf8))[0]
    } catch {
        XCTFail("could not decode JSON fragment \(fragment): \(error)", file: file, line: line)
        return LooseNumber(nil)
    }
}

/// The tray set from the live H2C payload captured mid-dry: one type with no preset data, one whose
/// preset exceeds the AMS 2 Pro's ceiling, and a preset/no-preset pair of the same type.
private func liveTrays() -> [AmsTray] {
    [
        AmsTray(id: 0, trayType: "PLA", trayColor: "161616FF", dryingTemp: 0, dryingTime: 0),
        AmsTray(id: 1, trayType: "PLA-S", trayColor: "00000000", dryingTemp: 70, dryingTime: 8),
        AmsTray(id: 2, trayType: "PETG", trayColor: "C9A38180", dryingTemp: 65, dryingTime: 8),
        AmsTray(id: 3, trayType: "PETG", trayColor: "FFFFFFFF", dryingTemp: 0, dryingTime: 0),
    ]
}

/// The exact live H2C unit captured MID-DRY (2026-07-12): a Handy-started cycle, so `dryTargetTemp`
/// is absent and — crucially — `dryStatus` is 0 while it is actively drying.
private func liveUnit(
    id: Int = 0,
    humidity: LooseNumber? = 25,
    temp: LooseNumber? = 44.7,
    isAmsHt: Bool? = false,
    moduleType: String? = "n3f",
    dryTime: LooseNumber? = 344,
    dryStatus: LooseNumber? = 0,
    drySubStatus: LooseNumber? = 0,
    dryTargetTemp: LooseNumber? = nil,
    dryFilament: String? = "PLA",
    drySfReason: [LooseNumber]? = [],
    tray: [AmsTray]? = liveTrays()
) -> AmsUnitRaw {
    AmsUnitRaw(
        id: id,
        humidity: humidity,
        temp: temp,
        isAmsHt: isAmsHt,
        moduleType: moduleType,
        dryTime: dryTime,
        dryStatus: dryStatus,
        drySubStatus: drySubStatus,
        dryTargetTemp: dryTargetTemp,
        dryFilament: dryFilament,
        drySfReason: drySfReason,
        tray: tray
    )
}

private func dryingStatus(_ units: [AmsUnitRaw], supportsDrying: Bool? = true) -> PrinterStatus {
    PrinterStatus(connected: true, state: "IDLE", ams: units, supportsDrying: supportsDrying)
}

final class DryerTests: XCTestCase {

    private func firstDryer(_ status: PrinterStatus) throws -> DryerVM {
        try XCTUnwrap(Dryer.present(status).first)
    }

    private func optionsByType(_ vm: DryerVM) -> [String: DryOption] {
        Dictionary(uniqueKeysWithValues: vm.options.map { ($0.type, $0) })
    }

    // MARK: - The live payload

    func testLivePayloadDryTimeAboveZeroMeansActiveEvenWithDryStatusZero() throws {
        let d = try firstDryer(dryingStatus([liveUnit()]))
        XCTAssertTrue(d.active)
        XCTAssertEqual(d.remainingMin, 344)
        XCTAssertEqual(d.remainingText, "5h 44m")
        XCTAssertEqual(d.filament, "PLA")
        XCTAssertEqual(d.humidityPct, 25)
    }

    func testHandyStartedCycleFallsBackToTheDryingFilamentsRecommendation() throws {
        let d = try firstDryer(dryingStatus([liveUnit()]))
        // dryFilament = PLA, and the PLA tray carries no preset -> the PLA fallback (55).
        XCTAssertEqual(d.targetTemp, 55)
        // 44.7 < 55 - 3 -> still climbing.
        XCTAssertEqual(d.stage, .heating)
    }

    func testOptionsAreDedupedByTypeAndTheAms2ProClampsTo65() throws {
        let d = try firstDryer(dryingStatus([liveUnit()]))
        let byType = optionsByType(d)
        XCTAssertEqual(d.options.count, 3)   // PLA, PLA-S, PETG (the two PETG trays dedupe)
        // PLA-S's preset says 70° but this unit (isAmsHt = false) tops out at 65°.
        XCTAssertEqual(byType["PLA-S"]?.temp, 65)
        XCTAssertEqual(byType["PLA-S"]?.hours, 8)
        XCTAssertEqual(byType["PLA-S"]?.fromPreset, true)
        // PETG: the 65/8 preset tray wins over its 0/0 sibling.
        XCTAssertEqual(byType["PETG"]?.temp, 65)
        XCTAssertEqual(byType["PETG"]?.hours, 8)
        XCTAssertEqual(byType["PETG"]?.fromPreset, true)
        // PLA: no preset -> fallback.
        XCTAssertEqual(byType["PLA"]?.temp, 55)
        XCTAssertEqual(byType["PLA"]?.hours, 8)
        XCTAssertEqual(byType["PLA"]?.fromPreset, false)
        XCTAssertEqual(byType["PLA"]?.color, "#161616")
    }

    func testAmsHtCeilingLetsAn80DegreePresetSurviveUnclamped() throws {
        let unit = liveUnit(isAmsHt: true, tray: [AmsTray(id: 0, trayType: "PA", dryingTemp: 80, dryingTime: 12)])
        let d = try firstDryer(dryingStatus([unit]))
        XCTAssertEqual(d.maxTemp, 85)
        XCTAssertEqual(d.options.first?.type, "PA")
        XCTAssertEqual(d.options.first?.temp, 80)
        XCTAssertEqual(d.options.first?.hours, 12)
    }

    // MARK: - WebSocket string forms

    func testWebSocketStringFormNumericFieldsStillWork() throws {
        let unit = liveUnit(
            humidity: wsNumber("\"25\""),
            temp: wsNumber("\"44.7\""),
            dryTime: wsNumber("\"344\""),
            dryTargetTemp: wsNumber("\"60\"")
        )
        let d = try firstDryer(dryingStatus([unit]))
        XCTAssertTrue(d.active)
        XCTAssertEqual(d.humidityPct, 25)
        XCTAssertEqual(d.targetTemp, 60)   // an explicit target beats the recommendation fallback
        XCTAssertEqual(d.stage, .heating)  // 44.7 < 60 - 3
    }

    /// The exact live WebSocket frame (2026-07-12). Its serializer differs from REST for the very
    /// same status: `dryTargetTemp` arrives as 0 (REST: null), `temp` as a string, `drySfReason` as
    /// [6]. The 0 target must be read as UNKNOWN, never rendered ("holding 0°" — user-reported).
    func testWebSocketFrameZeroTargetMeansUnknownSoNeverZeroDegrees() throws {
        let unit = liveUnit(
            humidity: 25,
            temp: wsNumber("\"44.7\""),
            dryTime: 312,
            dryStatus: 2,
            drySubStatus: 2,
            dryTargetTemp: 0,
            drySfReason: [6]
        )
        let d = try firstDryer(dryingStatus([unit]))
        XCTAssertTrue(d.active)
        XCTAssertEqual(d.targetTemp, 55)   // the PLA fallback, NOT 0
        XCTAssertEqual(d.stage, .heating)  // 44.7 < 55 - 3
        XCTAssertEqual(d.blockers, [])     // code 6 (already drying) stays omitted
    }

    // MARK: - Stage

    func testHoldingStageOnceAtTemperature() throws {
        let d = try firstDryer(dryingStatus([liveUnit(temp: 54.2, dryTargetTemp: 55)]))
        XCTAssertEqual(d.stage, .holding)  // 54.2 >= 55 - 3
    }

    func testIdleUnitIsNotActiveAndHasNoStage() throws {
        let d = try firstDryer(dryingStatus([liveUnit(dryTime: 0)]))
        XCTAssertFalse(d.active)
        XCTAssertNil(d.stage)
        XCTAssertEqual(d.remainingText, "—")
        XCTAssertEqual(d.options.count, 3)  // config options are still offered
    }

    func testActiveCycleWithUnknownFilamentHasNoTargetAndNoStage() throws {
        let d = try firstDryer(dryingStatus([liveUnit(dryTargetTemp: nil, dryFilament: nil)]))
        XCTAssertTrue(d.active)
        XCTAssertEqual(d.filament, "")
        XCTAssertNil(d.targetTemp)
        XCTAssertNil(d.stage)
    }

    func testFilamentWithNoMatchingTrayLeavesTheTargetUnknown() throws {
        // Drying PVA while no tray holds PVA: the recommendation fallback has nothing to match.
        let d = try firstDryer(dryingStatus([liveUnit(dryFilament: "PVA")]))
        XCTAssertTrue(d.active)
        XCTAssertNil(d.targetTemp)
        XCTAssertNil(d.stage)
    }

    // MARK: - Blockers

    func testBlockersDecodeToTextDropUnknownCodesAndOmitCode6() throws {
        let unit = liveUnit(drySfReason: [3, wsNumber("\"8\""), 6, 99])
        let d = try firstDryer(dryingStatus([unit]))
        XCTAssertEqual(d.blockers, [DryBlockers.messages[3], DryBlockers.messages[8]].compactMap { $0 })
        XCTAssertEqual(d.blockers.count, 2)
    }

    func testBlockersKeepPayloadOrderAndDropNullEntries() throws {
        let unit = liveUnit(drySfReason: [wsNumber("null"), 2, 0])
        let d = try firstDryer(dryingStatus([unit]))
        XCTAssertEqual(d.blockers, [DryBlockers.messages[2], DryBlockers.messages[0]].compactMap { $0 })
    }

    // MARK: - Which units get a card

    func testUnsupportedMachineOrNoAmsProducesNoDryers() {
        XCTAssertTrue(Dryer.present(nil).isEmpty)
        XCTAssertTrue(Dryer.present(dryingStatus([liveUnit()], supportsDrying: false)).isEmpty)
        XCTAssertTrue(Dryer.present(dryingStatus([liveUnit()], supportsDrying: nil)).isEmpty)
        XCTAssertTrue(Dryer.present(dryingStatus([])).isEmpty)
    }

    func testHeaterlessUnitGetsNoCardWhileDryCapableSiblingsStillDo() {
        let heaterless = AmsUnitRaw(
            id: 1, humidity: 40, temp: 28, isAmsHt: false, moduleType: "f1",
            tray: [AmsTray(id: 0, trayType: "PLA")]
        )
        let dryers = Dryer.present(dryingStatus([liveUnit(), heaterless]))
        XCTAssertEqual(dryers.count, 1)
        XCTAssertEqual(dryers[0].amsId, 0)
    }

    func testFailOpenUnitWithModuleTypeN3fButNoDryFieldsYetStillGetsACard() {
        let fresh = AmsUnitRaw(id: 1, moduleType: "n3f", tray: [AmsTray(id: 0, trayType: "PLA")])
        let dryers = Dryer.present(dryingStatus([fresh]))
        XCTAssertEqual(dryers.count, 1)
        XCTAssertFalse(dryers[0].active)
        XCTAssertEqual(dryers[0].maxTemp, 65)
    }

    func testFailOpenUnidentifiedUnitThatPublishesDryTimeGetsACard() {
        let mystery = AmsUnitRaw(id: 2, dryTime: 0, tray: [AmsTray(id: 0, trayType: "PLA")])
        XCTAssertEqual(Dryer.present(dryingStatus([mystery])).count, 1)
    }

    func testEveryDryCapableUnitGetsItsOwnVM() {
        let ht = liveUnit(id: 128, isAmsHt: true, moduleType: "n3s", dryTime: 0,
                          tray: [AmsTray(id: 0, trayType: "PETG-CF")])
        let dryers = Dryer.present(dryingStatus([liveUnit(id: 0), ht]))
        XCTAssertEqual(dryers.map(\.amsId), [0, 128])
        XCTAssertEqual(dryers.map(\.maxTemp), [65, 85])
        XCTAssertEqual(dryers.map(\.isHt), [false, true])
    }

    // MARK: - Options

    func testEmptyTraysProduceNoOptions() throws {
        let unit = liveUnit(dryTime: 0, tray: [AmsTray(id: 0), AmsTray(id: 1)])
        let d = try firstDryer(dryingStatus([unit]))
        XCTAssertEqual(d.options, [])
    }

    func testBlankTrayTypeIsTreatedAsEmpty() throws {
        let unit = liveUnit(dryTime: 0, tray: [AmsTray(id: 0, trayType: ""), AmsTray(id: 1, trayType: "PLA")])
        let d = try firstDryer(dryingStatus([unit]))
        XCTAssertEqual(d.options.map(\.type), ["PLA"])
    }

    /// A `Dictionary` has no order of its own, so the option list has to carry the tray order itself.
    func testOptionOrderFollowsTrayOrder() throws {
        let d = try firstDryer(dryingStatus([liveUnit()]))
        XCTAssertEqual(d.options.map(\.type), ["PLA", "PLA-S", "PETG"])
    }

    func testPresetTemperatureAndHoursAreClampedToTheLegalRange() throws {
        let unit = liveUnit(dryTime: 0, tray: [
            AmsTray(id: 0, trayType: "PLA", dryingTemp: 30, dryingTime: 0.2),
            AmsTray(id: 1, trayType: "PA", dryingTemp: 200, dryingTime: 100),
        ])
        let d = try firstDryer(dryingStatus([unit]))
        let byType = optionsByType(d)
        // 30 °C is below the 45 °C floor Bambuddy enforces, and 0.2 h rounds to 0 — both clamp up.
        XCTAssertEqual(byType["PLA"]?.temp, Dryer.minTemp)
        XCTAssertEqual(byType["PLA"]?.hours, 1)
        XCTAssertEqual(byType["PLA"]?.fromPreset, true)
        // 200° is above this unit's 65° heater ceiling, 100 h above the 24 h maximum.
        XCTAssertEqual(byType["PA"]?.temp, 65)
        XCTAssertEqual(byType["PA"]?.hours, Dryer.maxHours)
    }

    func testTrayColorFollowsTheAlphaSentinel() throws {
        let d = try firstDryer(dryingStatus([liveUnit()]))
        let byType = optionsByType(d)
        XCTAssertEqual(byType["PLA"]?.color, "#161616")
        XCTAssertEqual(byType["PETG"]?.color, "#C9A381")
        // Alpha "00" is the printer's "colour unknown" sentinel, not a black spool.
        let plaS = try XCTUnwrap(byType["PLA-S"])
        XCTAssertNil(plaS.color)
    }

    // MARK: - Defaults table

    func testDefaultForExactTypeThenBaseTypePrefixThenGeneric() {
        XCTAssertEqual(Dryer.defaultFor("PETG"), Dryer.defaults["PETG"])
        XCTAssertEqual(Dryer.defaultFor("PETG-CF"), Dryer.defaults["PETG"])  // prefix fallback
        XCTAssertEqual(Dryer.defaultFor("PLA-CF"), Dryer.defaults["PLA"])
        XCTAssertEqual(Dryer.defaultFor("WEIRDIUM"), DryRecommendation(temp: 55, hours: 8))
        XCTAssertEqual(Dryer.defaultFor("WEIRDIUM"), Dryer.generic)
    }

    /// A leading hyphen yields an EMPTY base type, which must miss the table rather than matching a
    /// later segment.
    func testDefaultForLeadingHyphenFallsThroughToGeneric() {
        XCTAssertEqual(Dryer.defaultFor("-PLA"), Dryer.generic)
        XCTAssertEqual(Dryer.defaultFor(""), Dryer.generic)
    }

    /// The table is keyed by the printer's exact spelling — no case folding, so no locale can change
    /// the answer (Turkish dotless-i and friends).
    func testDefaultForIsCaseSensitive() {
        XCTAssertEqual(Dryer.defaultFor("pla"), Dryer.generic)
        XCTAssertEqual(Dryer.defaultFor("Petg"), Dryer.generic)
    }

    func testBlockerCodesCoverZeroThroughEight() {
        for code in 0...8 {
            XCTAssertNotNil(DryBlockers.messages[code], "missing message for reason code \(code)")
        }
        XCTAssertEqual(DryBlockers.messages.count, 9)
    }

    // MARK: - Swift-specific edges

    /// `LooseNumber` keeps whatever the payload held, so a non-finite or unparsable value reaches the
    /// view-model — and `Int(Double)` traps on those. Nothing here may crash.
    func testNonFiniteAndUnparsableNumbersDegradeToUnknown() throws {
        let unit = liveUnit(
            humidity: wsNumber("\"abc\""),
            temp: wsNumber("\"inf\""),
            dryTime: wsNumber("\"nope\"")
        )
        let d = try firstDryer(dryingStatus([unit]))
        XCTAssertFalse(d.active)
        XCTAssertEqual(d.remainingMin, 0)
        XCTAssertEqual(d.remainingText, "—")
        XCTAssertNil(d.humidityPct)
        XCTAssertNil(d.tempC)
        XCTAssertNil(d.stage)
    }

    func testAbsurdlyLargeDryTimeSaturatesInsteadOfOverflowing() throws {
        let d = try firstDryer(dryingStatus([liveUnit(dryTime: wsNumber("1e30"))]))
        XCTAssertTrue(d.active)
        XCTAssertEqual(d.remainingMin, Int.max)
    }

    func testNegativeDryTimeIsFlooredAtZero() throws {
        let d = try firstDryer(dryingStatus([liveUnit(dryTime: wsNumber("-5"))]))
        XCTAssertFalse(d.active)
        XCTAssertEqual(d.remainingMin, 0)
    }

    func testHumidityIsRounded() throws {
        let d = try firstDryer(dryingStatus([liveUnit(humidity: 25.6)]))
        XCTAssertEqual(d.humidityPct, 26)
    }

    func testTempCKeepsItsFractionUnrounded() throws {
        let d = try firstDryer(dryingStatus([liveUnit()]))
        XCTAssertEqual(try XCTUnwrap(d.tempC), 44.7, accuracy: 0.0001)
    }

    /// The drying card looks its unit up with `amsUnits.first { $0.id == d.amsId }`, so `amsId` has to
    /// be the RAW unit id the topology also uses — an HT reports 128, not a positional index.
    func testAmsIdJoinsTheTopologyUnitId() throws {
        let ht = AmsUnitRaw(
            id: 128, isAmsHt: true, moduleType: "n3s", dryTime: 42,
            tray: [AmsTray(id: 0, trayType: "PETG-CF")]
        )
        let status = dryingStatus([ht])
        let d = try firstDryer(status)
        XCTAssertEqual(d.amsId, 128)
        let unit = AmsTopology.present(status).units.first { $0.id == d.amsId }
        XCTAssertEqual(unit?.label, "AMS HT")
        XCTAssertEqual(unit?.maxDryTemp, d.maxTemp)
        // PETG-CF has no entry of its own; the base type supplies 65/8, under the HT's 85° ceiling.
        XCTAssertEqual(d.options.first?.temp, 65)
        XCTAssertEqual(d.options.first?.hours, 8)
    }
}

import XCTest
@testable import Sprout

private func makePlug(
    id: Int = 1,
    name: String? = "H2C Printer Plug",
    printerId: Int? = nil,
    enabled: Bool? = nil,
    autoOn: Bool? = nil,
    autoOff: Bool? = nil,
    autoOffPersistent: Bool? = nil,
    offDelayMode: String? = nil,
    offDelayMinutes: LooseNumber? = nil,
    offTempThreshold: LooseNumber? = nil,
    autoOffAfterDrying: Bool? = nil,
    offDelayAfterDryingMinutes: LooseNumber? = nil,
    scheduleEnabled: Bool? = nil,
    scheduleOnTime: String? = nil,
    scheduleOffTime: String? = nil
) -> SmartPlug {
    SmartPlug(
        id: id,
        name: name,
        printerId: printerId,
        plugType: nil,
        enabled: enabled,
        lastState: nil,
        autoOn: autoOn,
        autoOff: autoOff,
        autoOffPersistent: autoOffPersistent,
        offDelayMode: offDelayMode,
        offDelayMinutes: offDelayMinutes,
        offTempThreshold: offTempThreshold,
        autoOffAfterDrying: autoOffAfterDrying,
        offDelayAfterDryingMinutes: offDelayAfterDryingMinutes,
        scheduleEnabled: scheduleEnabled,
        scheduleOnTime: scheduleOnTime,
        scheduleOffTime: scheduleOffTime
    )
}

private func keys(_ plug: SmartPlug) -> [PlugAutomation.Key] {
    Power.plugAutomations(plug).map(\.key)
}

private func detail(_ plug: SmartPlug) -> String {
    Power.plugAutomations(plug).first?.detail ?? ""
}

final class PowerTests: XCTestCase {

    // MARK: - plugAutomations

    func testReportsNothingForAPlugWithEveryRuleDisarmed() {
        let disarmed = makePlug(autoOn: false, autoOff: false, autoOffAfterDrying: false, scheduleEnabled: false)
        XCTAssertEqual(Power.plugAutomations(disarmed), [])
        XCTAssertEqual(Power.automationSummary(makePlug()), "Nothing switches this plug automatically.")
    }

    func testReturnsEmptyForAMissingPlugRatherThanCrashing() {
        XCTAssertEqual(Power.plugAutomations(nil), [])
        XCTAssertEqual(Power.automationSummary(nil), "Nothing switches this plug automatically.")
    }

    func testFlagsOnlyPowerCuttingRulesAsCuts() {
        let autoOn = Power.plugAutomations(makePlug(autoOn: true))
        XCTAssertEqual(autoOn.first?.key, .autoOn)
        XCTAssertEqual(autoOn.first?.cuts, false)
        XCTAssertEqual(Power.plugAutomations(makePlug(autoOff: true)).first?.cuts, true)
        XCTAssertEqual(Power.plugAutomations(makePlug(autoOffAfterDrying: true)).first?.cuts, true)
    }

    func testDescribesAutoOffByItsModeMinutesVersusHotendTemperature() {
        XCTAssertTrue(detail(makePlug(autoOff: true, offDelayMinutes: 12)).contains("12 min after a print"))
        let temp = detail(makePlug(autoOff: true, offDelayMode: "temperature", offTempThreshold: 55))
        XCTAssertTrue(temp.contains("below 55°C"), temp)
        XCTAssertFalse(temp.contains("min after"), temp)
    }

    func testFallsBackToTheServerDefaultsWhenThresholdsAreAbsent() {
        XCTAssertTrue(detail(makePlug(autoOff: true)).contains("5 min"))
        XCTAssertTrue(detail(makePlug(autoOff: true, offDelayMode: "temperature")).contains("70°C"))
        XCTAssertTrue(detail(makePlug(autoOffAfterDrying: true)).contains("10 min"))
    }

    func testAnUnrecognisedOffDelayModeIsTreatedAsMinutes() {
        // Only the exact string "temperature" selects the thermal shape of the rule.
        XCTAssertTrue(detail(makePlug(autoOff: true, offDelayMode: "time")).contains("5 min"))
        XCTAssertTrue(detail(makePlug(autoOff: true, offDelayMode: "Temperature")).contains("5 min"))
    }

    func testCallsOutAPersistentAutoOffWhichSurvivesARestart() {
        XCTAssertTrue(detail(makePlug(autoOff: true, autoOffPersistent: true)).contains("Survives a Bambuddy restart"))
        XCTAssertFalse(detail(makePlug(autoOff: true)).contains("Survives"))
    }

    func testDescribesTheDryingRuleDistinctlyFromThePrintRule() {
        let both = Power.plugAutomations(makePlug(autoOff: true, autoOffAfterDrying: true, offDelayAfterDryingMinutes: 20))
        XCTAssertEqual(both.map(\.key), [.autoOff, .afterDrying])
        XCTAssertTrue(both[1].detail.contains("20 min after AMS drying"), both[1].detail)
    }

    func testListsEveryArmedRuleInAStableReadableOrder() {
        let all = makePlug(autoOn: true, autoOff: true, autoOffAfterDrying: true,
                           scheduleEnabled: true, scheduleOffTime: "23:00")
        XCTAssertEqual(keys(all), [.autoOn, .autoOff, .afterDrying, .schedule])
        XCTAssertEqual(Power.automationSummary(all),
                       "Auto power-on · Auto power-off · Off after drying · Schedule")
    }

    func testASingleArmedRuleSummarisesWithoutASeparator() {
        XCTAssertEqual(Power.automationSummary(makePlug(autoOn: true)), "Auto power-on")
    }

    // MARK: - plugAutomations: schedule

    func testScheduleRendersBothEdgesAndCountsTheOffEdgeAsCutting() {
        let s = Power.plugAutomations(makePlug(scheduleEnabled: true, scheduleOnTime: "07:00", scheduleOffTime: "22:30"))[0]
        XCTAssertEqual(s.detail, "Switches on at 07:00, off at 22:30 every day.")
        XCTAssertTrue(s.cuts)
    }

    func testAnOnOnlyScheduleCannotCutPower() {
        let s = Power.plugAutomations(makePlug(scheduleEnabled: true, scheduleOnTime: "07:00"))[0]
        XCTAssertEqual(s.detail, "Switches on at 07:00 every day.")
        XCTAssertFalse(s.cuts)
    }

    func testAnOffOnlyScheduleReadsAsOneClause() {
        let s = Power.plugAutomations(makePlug(scheduleEnabled: true, scheduleOffTime: "22:30"))[0]
        XCTAssertEqual(s.detail, "Switches off at 22:30 every day.")
        XCTAssertTrue(s.cuts)
    }

    func testScheduleIsNotReportedWhenEnabledWithNoTimes() {
        XCTAssertEqual(keys(makePlug(scheduleEnabled: true)), [])
        XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOnTime: nil, scheduleOffTime: nil)), [])
    }

    func testScheduleIgnoresMalformedTimesRatherThanPrintingThem() {
        XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOnTime: "25:00")), [])
        XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOnTime: "soon")), [])
        XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOnTime: "7:00")), [])       // needs zero-padding
        XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOffTime: "00:00")), [.schedule]) // midnight is valid
    }

    func testScheduleRejectsEveryOutOfRangeOrMisShapedTime() {
        for bad in ["", "0700", "24:00", "07:60", "99:99", "07;00", "07:0", "007:00", "07:000", "-7:00"] {
            XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOnTime: bad)), [], "accepted \(bad)")
        }
    }

    func testScheduleRejectsNonAsciiDigits() {
        // Swift's regex `\d` matches any Unicode decimal digit, so a regex port would accept these
        // and render them into the sentence. The hand-rolled parser must not.
        XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOnTime: "٠٧:٠٠")), [])
        XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOnTime: "０７:００")), [])
    }

    func testScheduleRejectsSurroundingWhitespace() {
        for bad in [" 07:00", "07:00 ", "07:00\n", "\t07:00"] {
            XCTAssertEqual(keys(makePlug(scheduleEnabled: true, scheduleOnTime: bad)), [], "accepted \(bad)")
        }
    }

    func testScheduleAcceptsBothEndsOfTheValidRange() {
        XCTAssertEqual(detail(makePlug(scheduleEnabled: true, scheduleOnTime: "00:00")), "Switches on at 00:00 every day.")
        XCTAssertEqual(detail(makePlug(scheduleEnabled: true, scheduleOnTime: "23:59")), "Switches on at 23:59 every day.")
        XCTAssertEqual(detail(makePlug(scheduleEnabled: true, scheduleOnTime: "19:05")), "Switches on at 19:05 every day.")
    }

    func testScheduleIsNotReportedWhenDisabledTimesOrNot() {
        XCTAssertEqual(keys(makePlug(scheduleEnabled: false, scheduleOnTime: "07:00", scheduleOffTime: "22:00")), [])
    }

    func testAMalformedOffTimeCannotMakeAnOnOnlyScheduleLookCutting() {
        let s = Power.plugAutomations(makePlug(scheduleEnabled: true, scheduleOnTime: "07:00", scheduleOffTime: "nope"))[0]
        XCTAssertEqual(s.detail, "Switches on at 07:00 every day.")
        XCTAssertFalse(s.cuts)
    }

    // MARK: - plugAutomations: threshold rendering

    func testAWholeThresholdRendersWithoutADecimalTail() {
        XCTAssertEqual(detail(makePlug(autoOff: true, offDelayMinutes: 12.0)),
                       "Switches off 12 min after a print finishes.")
    }

    func testAFractionalThresholdKeepsItsFraction() {
        XCTAssertEqual(detail(makePlug(autoOff: true, offDelayMode: "temperature", offTempThreshold: 55.5)),
                       "Switches off after a print, once the hotend cools below 55.5°C.")
    }

    func testZeroIsAThresholdNotAMissingValue() {
        XCTAssertEqual(detail(makePlug(autoOff: true, offDelayMinutes: 0)),
                       "Switches off 0 min after a print finishes.")
    }

    func testAThresholdThatArrivedAsAStringOverTheWebSocketStillRenders() throws {
        let stringified = try JSONDecoder().decode(LooseNumber.self, from: Data(#""12""#.utf8))
        XCTAssertEqual(detail(makePlug(autoOff: true, offDelayMinutes: stringified)),
                       "Switches off 12 min after a print finishes.")
    }

    func testANonFiniteThresholdFallsBackToTheServerDefault() {
        // `Double("nan")` parses, so a stringified numeric can carry NaN this far.
        XCTAssertEqual(detail(makePlug(autoOff: true, offDelayMinutes: LooseNumber(Double.nan))),
                       "Switches off 5 min after a print finishes.")
        XCTAssertEqual(detail(makePlug(autoOff: true, offDelayMode: "temperature",
                                       offTempThreshold: LooseNumber(Double.infinity))),
                       "Switches off after a print, once the hotend cools below 70°C.")
    }

    func testAThresholdTooLargeForAnIntDoesNotTrap() {
        let text = detail(makePlug(autoOff: true, offDelayMinutes: LooseNumber(1e30)))
        XCTAssertTrue(text.hasPrefix("Switches off "), text)
        XCTAssertTrue(text.hasSuffix(" min after a print finishes."), text)
    }

    // MARK: - otherPlugs

    private var allPlugs: [SmartPlug] {
        [
            makePlug(id: 5, name: "Meaco AC Plug"),
            makePlug(id: 2, name: "H2C Printer Plug", printerId: 2),
            makePlug(id: 4, name: "AMS HT Plug"),
            makePlug(id: 3, name: "AMS 2 Pro Plug"),
        ]
    }

    func testExcludesThePrinterPlugAndSortsById() {
        XCTAssertEqual(Power.otherPlugs(allPlugs, printerPlugId: 2).map(\.id), [3, 4, 5])
    }

    func testKeepsEveryPlugWhenThePrinterHasNoneLinked() {
        XCTAssertEqual(Power.otherPlugs(allPlugs, printerPlugId: nil).map(\.id), [2, 3, 4, 5])
        XCTAssertEqual(Power.otherPlugs(allPlugs, printerPlugId: nil).count, 4)
    }

    func testKeepsEveryPlugWhenThePrinterPlugIdMatchesNoSocket() {
        XCTAssertEqual(Power.otherPlugs(allPlugs, printerPlugId: 99).map(\.id), [2, 3, 4, 5])
    }

    func testDropsDisabledPlugsBecauseBambuddyWillNotActOnThem() {
        let withDead = allPlugs + [makePlug(id: 9, name: "Old", enabled: false)]
        XCTAssertEqual(Power.otherPlugs(withDead, printerPlugId: 2).map(\.id), [3, 4, 5])
        XCTAssertEqual(Power.otherPlugs([makePlug(id: 9, name: "Kept", enabled: true)], printerPlugId: nil).count, 1)
    }

    func testKeepsAPlugThatNeverStatesWhetherItIsEnabled() {
        // Absent means enabled; only an explicit false drops the row.
        XCTAssertEqual(Power.otherPlugs([makePlug(id: 9, name: "Unstated", enabled: nil)], printerPlugId: nil).count, 1)
    }

    func testSurvivesAnEmptyOrMissingList() {
        XCTAssertEqual(Power.otherPlugs([], printerPlugId: 2), [])
        XCTAssertEqual(Power.otherPlugs(nil, printerPlugId: 2), [])
        XCTAssertEqual(Power.otherPlugs(nil, printerPlugId: nil), [])
    }

    // MARK: - otherPlugs: listing every socket, not just the peripherals

    /// All three sockets are on one physical strip (a P304M), so hiding the printer's own socket made
    /// the strip look like it was missing one — even though that socket drives the big control above.
    private var strip: [SmartPlug] {
        [
            makePlug(id: 2, name: "H2C Printer Plug", printerId: 2),
            makePlug(id: 3, name: "AMS 2 Pro Plug"),
            makePlug(id: 4, name: "AMS HT Plug"),
        ]
    }

    func testPassingNilKeepsThePrinterPlugInTheList() {
        XCTAssertEqual(Power.otherPlugs(strip, printerPlugId: nil).map(\.id), [2, 3, 4])
    }

    func testStillExcludesItWhenACallerGenuinelyWantsOnlyTheOthers() {
        XCTAssertEqual(Power.otherPlugs(strip, printerPlugId: 2).map(\.id), [3, 4])
    }

    func testDropsADisabledSocketEitherWay() {
        // A deleted Home Assistant entity can never report, whichever list it would appear in.
        let withDead = strip + [makePlug(id: 1, name: "3D Printer Plug", enabled: false)]
        XCTAssertEqual(Power.otherPlugs(withDead, printerPlugId: nil).map(\.id), [2, 3, 4])
        XCTAssertEqual(Power.otherPlugs(withDead, printerPlugId: 2).map(\.id), [3, 4])
    }

    // MARK: - plugLabel

    func testPrefersTheNameFallsBackToTheIdNeverRendersBlank() {
        XCTAssertEqual(Power.plugLabel(makePlug(id: 3, name: "AMS HT Plug")), "AMS HT Plug")
        XCTAssertEqual(Power.plugLabel(makePlug(id: 3, name: "   ")), "Plug 3")
        XCTAssertEqual(Power.plugLabel(makePlug(id: 3, name: nil)), "Plug 3")
        XCTAssertEqual(Power.plugLabel(makePlug(id: 3, name: "")), "Plug 3")
        XCTAssertEqual(Power.plugLabel(nil), "Smart plug")
    }

    func testReturnsTheTrimmedNameNotTheRawOne() {
        XCTAssertEqual(Power.plugLabel(makePlug(id: 3, name: "  AMS HT Plug \n")), "AMS HT Plug")
        XCTAssertEqual(Power.plugLabel(makePlug(id: 3, name: "\t\n ")), "Plug 3")
    }

    func testTheIdFallbackIsNotLocaleFormatted() {
        // Interpolation must not group thousands the way a NumberFormatter would.
        XCTAssertEqual(Power.plugLabel(makePlug(id: 1_234_567, name: nil)), "Plug 1234567")
        XCTAssertEqual(Power.plugLabel(makePlug(id: 0, name: nil)), "Plug 0")
    }
}

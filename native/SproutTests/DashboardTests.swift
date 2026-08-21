import XCTest
@testable import Sprout

/// `Dash.present` is the single source of print-state classification, so these cover every branch
/// and the two numbering schemes that used to be compared index-to-index.
final class DashboardTests: XCTestCase {

    private func status(
        connected: Bool = true,
        state: String = "RUNNING",
        progress: Double? = nil,
        printError: Double? = nil,
        stage: String? = nil,
        temps: Temperatures? = nil,
        activeExtruder: Int? = nil
    ) -> PrinterStatus {
        var s = PrinterStatus()
        s.connected = connected
        s.state = state
        s.progress = progress.map { LooseNumber($0) }
        s.printError = printError.map { LooseNumber($0) }
        s.stgCurName = stage
        s.temperatures = temps
        s.activeExtruder = activeExtruder.map { LooseNumber(Double($0)) }
        return s
    }

    // MARK: - Kind classification

    func testNilStatusIsConnecting() {
        let vm = Dash.present(nil)
        XCTAssertEqual(vm.kind, .connecting)
        XCTAssertEqual(vm.stateLabel, "Connecting")
        XCTAssertEqual(vm.stateColor, .idle)
    }

    func testDisconnectedIsOffline() {
        let vm = Dash.present(status(connected: false))
        XCTAssertEqual(vm.kind, .offline)
        XCTAssertEqual(vm.stateLabel, "Offline")
        XCTAssertEqual(vm.heroSub, "No response from the printer")
    }

    func testPrintErrorIsAnError() {
        let vm = Dash.present(status(printError: 12))
        XCTAssertEqual(vm.kind, .error)
        XCTAssertEqual(vm.stateColor, .error)
    }

    func testFailedStateIsAnError() {
        XCTAssertEqual(Dash.present(status(state: "FAILED")).kind, .error)
        XCTAssertEqual(Dash.present(status(state: "ERROR")).kind, .error)
    }

    /// An HMS notice alone is NOT an error — the machine emits benign ones mid-print.
    func testHmsNoticesAloneDoNotMakeAnError() {
        var s = status(state: "RUNNING")
        s.hmsErrors = [HmsError(code: "0500", fullCode: "0500050000010007")]
        let vm = Dash.present(s)
        XCTAssertEqual(vm.kind, .live)
        XCTAssertEqual(vm.hmsCount, 1)
        XCTAssertEqual(vm.hmsCode, "0500-0500-0001-0007")
    }

    func testPauseIsLiveAndPaused() {
        for state in ["PAUSE", "PAUSED"] {
            let vm = Dash.present(status(state: state))
            XCTAssertEqual(vm.kind, .live, state)
            XCTAssertTrue(vm.isPaused, state)
            XCTAssertEqual(vm.stateColor, .paused, state)
        }
    }

    func testFinishVariantsAreComplete() {
        for state in ["FINISH", "FINISHED", "FINISHING"] {
            XCTAssertEqual(Dash.present(status(state: state)).kind, .complete, state)
        }
    }

    func testIdleVariants() {
        for state in ["IDLE", "", "UNKNOWN"] {
            let vm = Dash.present(status(state: state))
            XCTAssertEqual(vm.kind, .idle, state)
            XCTAssertEqual(vm.heroSub, "No active job")
        }
    }

    func testStageNameWinsOverHeatingHeuristic() {
        let vm = Dash.present(status(state: "RUNNING", progress: 1, stage: "Auto bed leveling"))
        XCTAssertEqual(vm.stateLabel, "Auto bed leveling")
        XCTAssertEqual(vm.stateColor, .heating)
    }

    /// A stage literally named "printing" is not a sub-stage — it must not suppress the heuristic.
    func testStageNamedPrintingIsIgnored() {
        var t = Temperatures()
        t.nozzle = 40
        t.nozzleTarget = 220
        let vm = Dash.present(status(state: "RUNNING", progress: 0, stage: "printing", temps: t))
        XCTAssertEqual(vm.stateLabel, "Heating")
    }

    func testHeatingOnlyCountsBelowTwoPercent() {
        var t = Temperatures()
        t.nozzle = 40
        t.nozzleTarget = 220
        XCTAssertEqual(Dash.present(status(state: "RUNNING", progress: 1, temps: t)).stateLabel, "Heating")
        XCTAssertEqual(Dash.present(status(state: "RUNNING", progress: 40, temps: t)).stateLabel, "Printing")
    }

    // MARK: - Nozzle selection

    /// Temperature keys are position-ordered (nozzle = LEFT); `activeExtruder` uses Bambu's ids
    /// where 0 = RIGHT. Comparing them index-to-index is the bug this guards.
    func testActiveExtruderZeroSelectsTheSecondTemperatureKey() {
        var t = Temperatures()
        t.nozzle = 44; t.nozzleTarget = 0
        t.nozzle2 = 220; t.nozzle2Target = 220
        let vm = Dash.present(status(temps: t, activeExtruder: 0))
        XCTAssertEqual(vm.nozzles.count, 2)
        XCTAssertTrue(vm.nozzles[1].active, "extruder 0 is the RIGHT head, which is nozzle_2")
        XCTAssertEqual(vm.nozzleNow, 220)
    }

    func testDrivenHeadWinsOverActiveExtruder() {
        var t = Temperatures()
        t.nozzle = 245; t.nozzleTarget = 245
        t.nozzle2 = 40; t.nozzle2Target = 0
        // activeExtruder says RIGHT, but only the LEFT head is driven — driven wins.
        let vm = Dash.present(status(temps: t, activeExtruder: 0))
        XCTAssertTrue(vm.nozzles[0].active)
        XCTAssertEqual(vm.nozzleNow, 245)
    }

    func testHotterHeadBreaksTheTieWhenNeitherIsDriven() {
        var t = Temperatures()
        t.nozzle = 60; t.nozzleTarget = 0
        t.nozzle2 = 90; t.nozzleTarget = 0
        t.nozzle2Target = 0
        let vm = Dash.present(status(temps: t, activeExtruder: nil))
        XCTAssertTrue(vm.nozzles[1].active)
    }

    func testSingleNozzleMachineHasOneAlwaysActiveNozzle() {
        var t = Temperatures()
        t.nozzle = 210; t.nozzleTarget = 220
        let vm = Dash.present(status(temps: t))
        XCTAssertEqual(vm.nozzles.count, 1)
        XCTAssertTrue(vm.nozzles[0].active)
    }

    // MARK: - Heating derivation

    func testExplicitHeatingFlagBeatsTheGapHeuristic() {
        var t = Temperatures()
        t.bed = 20; t.bedTarget = 60; t.bedHeating = false
        XCTAssertFalse(Dash.present(status(temps: t)).bedHeating)
    }

    func testHeatingDerivedFromGapWhenFlagAbsent() {
        var t = Temperatures()
        t.bed = 20; t.bedTarget = 60
        XCTAssertTrue(Dash.present(status(temps: t)).bedHeating)

        t.bed = 59
        XCTAssertFalse(Dash.present(status(temps: t)).bedHeating, "within the 2° gap counts as at temperature")
    }

    func testChamberOnlyPresentWhenReported() {
        XCTAssertFalse(Dash.present(status()).hasChamber)
        var t = Temperatures()
        t.chamber = 35
        XCTAssertTrue(Dash.present(status(temps: t)).hasChamber)
    }

    // MARK: - Speed

    func testSpeedFallsBackToStandardWhenOutOfRange() {
        var s = status()
        s.speedLevel = 9
        XCTAssertEqual(Dash.present(s).speedIdx, 2)
        XCTAssertEqual(Dash.present(s).speedLabel, "Standard")
    }

    func testSpeedUsesTheReportedLevel() {
        var s = status()
        s.speedLevel = 4
        XCTAssertEqual(Dash.present(s).speedLabel, "Ludicrous")
    }

    // MARK: - Formatters

    func testFmtDuration() {
        XCTAssertEqual(Dash.fmtDuration(0), "—")
        XCTAssertEqual(Dash.fmtDuration(-5), "—")
        XCTAssertEqual(Dash.fmtDuration(.infinity), "—")
        XCTAssertEqual(Dash.fmtDuration(45), "45m")
        XCTAssertEqual(Dash.fmtDuration(60), "1h 00m")
        XCTAssertEqual(Dash.fmtDuration(125), "2h 05m")
    }

    func testFmtClockIsTwelveHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(timeZone: cal.timeZone, year: 2026, month: 8, day: 10, hour: h, minute: m))!
        }
        XCTAssertEqual(Dash.fmtClock(at(0, 5), calendar: cal), "12:05 AM")
        XCTAssertEqual(Dash.fmtClock(at(12, 0), calendar: cal), "12:00 PM")
        XCTAssertEqual(Dash.fmtClock(at(13, 30), calendar: cal), "1:30 PM")
        XCTAssertEqual(Dash.fmtClock(at(23, 9), calendar: cal), "11:09 PM")
    }

    func testFmtHmsCode() {
        XCTAssertNil(Dash.fmtHmsCode(nil))
        XCTAssertEqual(Dash.fmtHmsCode("0500050000010007"), "0500-0500-0001-0007")
        // Anything not exactly 16 characters passes through untouched rather than being mangled.
        XCTAssertEqual(Dash.fmtHmsCode("0500"), "0500")
    }

    // MARK: - Stringified numbers

    /// The WebSocket sends numerics as strings; decoding must absorb that so no read site can crash.
    func testStringifiedNumbersDecode() throws {
        let json = """
        {"connected": true, "state": "RUNNING", "progress": "42.6", "layer_num": "17",
         "temperatures": {"nozzle": "219.8", "nozzle_target": "220"}}
        """.data(using: .utf8)!
        let s = try BambuddyClient.decoder.decode(PrinterStatus.self, from: json)
        let vm = Dash.present(s)
        XCTAssertEqual(vm.progressInt, 43)
        XCTAssertEqual(vm.layer, "17")
        XCTAssertEqual(vm.nozzleNow, 220)
    }
}

/// `Dash.isNamedStage` decides whether the printer's sub-stage becomes the headline.
///
/// The predicate has to ask "did the printer NAME this stage", not "is there a string". Bambuddy
/// answers `Unknown stage (79)` for any sub-stage code it has no name for, and that reached the
/// lock screen verbatim: a print opened under the headline "Unknown stage (79)" instead of
/// "Printing".
final class NamedStageTests: XCTestCase {
    func testARealStageNameIsUsed() {
        XCTAssertTrue(Dash.isNamedStage("Changing filament"))
        XCTAssertTrue(Dash.isNamedStage("Auto bed leveling"))
    }

    func testUnnamedCodesAreNotStageNames() {
        XCTAssertFalse(Dash.isNamedStage("Unknown stage (79)"))
        XCTAssertFalse(Dash.isNamedStage("unknown stage (3)"))
        XCTAssertFalse(Dash.isNamedStage("  Unknown stage (79)  "))
    }

    func testAbsentOrRedundantStagesFallThrough() {
        XCTAssertFalse(Dash.isNamedStage(""))
        XCTAssertFalse(Dash.isNamedStage("   "))
        // Already the headline the fallback produces; repeating it says nothing.
        XCTAssertFalse(Dash.isNamedStage("Printing"))
        XCTAssertFalse(Dash.isNamedStage("printing"))
    }
}

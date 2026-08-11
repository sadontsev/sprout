import XCTest
@testable import Sprout

/// The content mapping and change gating behind Live Activity cards. The wire format matters as much
/// as the logic: Trellis pushes this exact shape over APNs.
final class LiveActivityTests: XCTestCase {

    private func running(progress: Double = 40, remaining: Double = 90) -> PrinterStatus {
        var s = PrinterStatus()
        s.connected = true
        s.state = "RUNNING"
        s.progress = LooseNumber(progress)
        s.remainingTime = LooseNumber(remaining)
        s.subtaskName = "bracket.3mf"
        s.layerNum = 42
        s.totalLayers = 210
        var t = Temperatures()
        t.nozzle = 220; t.nozzleTarget = 220
        t.bed = 60; t.bedTarget = 60
        s.temperatures = t
        return s
    }

    // MARK: - Wire format

    /// The property names are what Trellis sends. A rename breaks remote updates silently.
    func testContentStateEncodesTheServersFieldNames() throws {
        let state = LiveActivityController.content(vm: Dash.present(running()), status: running(), printerName: "H2C")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        let keys = Set(json?.keys ?? [:].keys)
        for expected in [
            "printerName", "name", "stateLabel", "progress", "layer", "totalLayers", "etaEpochMs",
            "finished", "symbol", "iconUri", "tint", "nozzle", "nozzleTarget", "nozzle2",
            "nozzle2Target", "hasNozzle2", "activeNozzle", "bed", "bedTarget", "modelUri",
            "queueCount", "nextName",
        ] {
            XCTAssertTrue(keys.contains(expected), "missing wire field \(expected)")
        }
    }

    func testServerPushedPayloadDecodes() throws {
        let payload = """
        {"printerName":"H2C","name":"bracket.3mf","stateLabel":"Printing","progress":42,
         "layer":10,"totalLayers":200,"etaEpochMs":1786000000000,"finished":false,
         "symbol":"printer.fill","iconUri":"","tint":"#30D158","nozzle":220,"nozzleTarget":220,
         "nozzle2":0,"nozzle2Target":0,"hasNozzle2":false,"activeNozzle":0,"bed":60,"bedTarget":60,
         "modelUri":"","queueCount":2,"nextName":"next.3mf"}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(PrintActivityAttributes.ContentState.self, from: payload)
        XCTAssertEqual(state.progress, 42)
        XCTAssertEqual(state.queueCount, 2)
        XCTAssertEqual(state.nextName, "next.3mf")
        XCTAssertNotNil(state.etaDate)
    }

    // MARK: - Tint

    /// Fixed hexes, not theme tokens: a card built by the app and one pushed by the server have to
    /// render the same print in the same colour.
    func testTintIsThemeIndependent() {
        var s = running()
        XCTAssertEqual(LiveActivityController.tint(Dash.present(s)), LAColors.running)

        s.state = "PAUSE"
        XCTAssertEqual(LiveActivityController.tint(Dash.present(s)), LAColors.paused)

        s.state = "FAILED"
        XCTAssertEqual(LiveActivityController.tint(Dash.present(s)), LAColors.error)

        s.state = "IDLE"
        XCTAssertEqual(LiveActivityController.tint(Dash.present(s)), LAColors.idle)

        s.state = "FINISH"
        XCTAssertEqual(LiveActivityController.tint(Dash.present(s)), LAColors.running)
    }

    func testHeatingIsAmber() {
        var s = running(progress: 0)
        var t = Temperatures()
        t.nozzle = 30; t.nozzleTarget = 220
        s.temperatures = t
        XCTAssertEqual(LiveActivityController.tint(Dash.present(s)), LAColors.heating)
    }

    // MARK: - Content mapping

    func testEtaIsAbsoluteAndZeroWhenFinished() {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let live = LiveActivityController.content(vm: Dash.present(running()), status: running(), now: now)
        XCTAssertEqual(live.etaEpochMs, (now.timeIntervalSince1970 + 90 * 60) * 1000, accuracy: 1)

        var done = running()
        done.state = "FINISH"
        let complete = LiveActivityController.content(vm: Dash.present(done), status: done, now: now)
        XCTAssertEqual(complete.etaEpochMs, 0)
        XCTAssertTrue(complete.finished)
    }

    func testDualNozzleFlagsAndActiveHead() {
        var s = running()
        var t = s.temperatures!
        t.nozzle2 = 240; t.nozzle2Target = 240
        t.nozzleTarget = 0
        s.temperatures = t
        let state = LiveActivityController.content(vm: Dash.present(s), status: s)
        XCTAssertTrue(state.hasNozzle2)
        XCTAssertEqual(state.activeNozzle, 1, "only the right head is driven")
    }

    // MARK: - Drying

    private func drying(unit: Int, minutes: Double, isHt: Bool = false) -> PrinterStatus {
        var u = AmsUnitRaw(id: unit)
        u.dryTime = LooseNumber(minutes)
        u.dryTargetTemp = 55
        u.dryFilament = "PETG"
        u.temp = 48
        u.humidity = 22
        u.isAmsHt = isHt ? true : nil
        var s = PrinterStatus()
        s.connected = true
        s.state = "IDLE"
        s.ams = [u]
        return s
    }

    /// `dryTime > 0` is the active signal; `dryStatus` stayed 0 mid-cycle on the live machine.
    func testDryingUnitsDetectedByRemainingMinutes() {
        XCTAssertEqual(LiveActivityController.dryingUnitIds(drying(unit: 1, minutes: 120)), [1])
        XCTAssertEqual(LiveActivityController.dryingUnitIds(drying(unit: 1, minutes: 0)), [])
    }

    func testConcurrentCyclesEachReportTheirUnit() {
        var a = AmsUnitRaw(id: 0); a.dryTime = 60
        var b = AmsUnitRaw(id: 128); b.dryTime = 30; b.isAmsHt = true
        var s = PrinterStatus()
        s.ams = [a, b]
        XCTAssertEqual(LiveActivityController.dryingUnitIds(s), [0, 128])
    }

    /// A cycle on the HT produced no card at all when only ams[0] was scanned.
    func testDryContentFindsAnyUnitAndNamesIt() {
        let s = drying(unit: 128, minutes: 90, isHt: true)
        var second = AmsUnitRaw(id: 0)
        second.dryTime = 0
        var withBoth = s
        withBoth.ams = [second] + (s.ams ?? [])

        let card = LiveActivityController.dryContent(withBoth, amsId: 128)
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.dry, true)
        XCTAssertEqual(card?.stateLabel, "Drying")
        XCTAssertEqual(card?.tint, LAColors.drying)
        XCTAssertTrue(card?.name.contains("AMS HT") == true, "the card must say which unit is drying")
        XCTAssertEqual(card?.amsTarget, 55)
        XCTAssertEqual(card?.humidity, 22)
    }

    func testIdleUnitProducesNoDryCard() {
        XCTAssertNil(LiveActivityController.dryContent(drying(unit: 0, minutes: 0), amsId: 0))
    }

    // MARK: - Change gating

    func testFirstContentAlwaysCounts() {
        let s = LiveActivityController.content(vm: Dash.present(running()), status: running())
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: nil, to: s))
    }

    func testIdenticalContentIsNotAChange() {
        let s = LiveActivityController.content(vm: Dash.present(running()), status: running())
        XCTAssertFalse(LiveActivityController.meaningfulChange(from: s, to: s))
    }

    /// Without temperature in the comparison, a heat-up that doesn't advance progress or layer never
    /// pushes, and the card shows cold temps for minutes.
    func testTemperatureDriftCounts() {
        var a = LiveActivityController.content(vm: Dash.present(running()), status: running())
        var b = a
        b.nozzle = a.nozzle + 2
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: b))

        a.nozzle = 100; b = a; b.nozzle = 101
        XCTAssertFalse(LiveActivityController.meaningfulChange(from: a, to: b), "1° is below the threshold")
    }

    func testSubDegreeAndSubMinuteNoiseIsIgnored() {
        let a = LiveActivityController.content(vm: Dash.present(running()), status: running())
        var b = a
        b.etaEpochMs = a.etaEpochMs + 30_000
        XCTAssertFalse(LiveActivityController.meaningfulChange(from: a, to: b), "30s of ETA jitter is not worth a push")

        b.etaEpochMs = a.etaEpochMs + 61_000
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: b))
    }

    func testQueueChangesCount() {
        let a = LiveActivityController.content(vm: Dash.present(running()), status: running())
        var b = a
        b.queueCount = 3
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: b))
    }

    func testDryingReadoutsCount() {
        var a = PrintActivityAttributes.ContentState()
        a.dry = true; a.amsTemp = 40; a.humidity = 30
        var b = a
        b.amsTemp = 41
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: b), "the temp climb is the whole story")

        b = a; b.humidity = 28
        XCTAssertTrue(LiveActivityController.meaningfulChange(from: a, to: b))

        b = a; b.humidity = 31
        XCTAssertFalse(LiveActivityController.meaningfulChange(from: a, to: b))
    }
}

/// The single socket carries frames for every registered printer, so the id has to come out of the
/// frame rather than being assumed.
final class WsFrameTests: XCTestCase {

    func testParsesAPrinterStatusFrame() {
        let raw = #"{"type":"printer_status","printer_id":2,"data":{"connected":true,"state":"RUNNING"}}"#
        let frame = WsFrame.parse(raw)
        XCTAssertEqual(frame?.printerId, 2)
        XCTAssertEqual(frame?.status.state, "RUNNING")
    }

    func testIgnoresOtherFrameTypes() {
        XCTAssertNil(WsFrame.parse(#"{"type":"pong"}"#))
        XCTAssertNil(WsFrame.parse(#"{"type":"printer_status","printer_id":2}"#), "no data")
    }

    func testIgnoresGarbage() {
        XCTAssertNil(WsFrame.parse("not json"))
        XCTAssertNil(WsFrame.parse(""))
    }

    func testFiltersToTheRequestedPrinter() {
        let raw = #"{"type":"printer_status","printer_id":2,"data":{"connected":true,"state":"IDLE"}}"#
        XCTAssertNotNil(WsFrame.status(from: raw, printerId: 2))
        XCTAssertNil(WsFrame.status(from: raw, printerId: 3))
    }
}

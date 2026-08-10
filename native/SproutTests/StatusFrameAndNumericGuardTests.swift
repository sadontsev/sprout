import XCTest
@testable import Sprout

/// A frame the decoder rejects is a LOST status, not a heartbeat: while the socket is up the REST
/// fallback is off, so a silently dropped frame freezes the dashboard on its last good value.
/// `classify` is what lets the store tell the two apart.
final class WsFrameClassifyTests: XCTestCase {

    private func classify(_ raw: String) -> WsFrame.Outcome { WsFrame.classify(raw) }

    func testStatusFrameClassifiesAsStatus() {
        let raw = #"{"type":"printer_status","printer_id":7,"data":{"connected":true,"state":"RUNNING"}}"#
        guard case .status(let frame) = classify(raw) else { return XCTFail("expected .status") }
        XCTAssertEqual(frame.printerId, 7)
        XCTAssertEqual(frame.status.state, "RUNNING")
    }

    func testHeartbeatIsIgnored() {
        XCTAssertEqual(classify(#"{"type":"pong"}"#), .ignored)
    }

    /// The reason a lenient `data: PrinterStatus?` is not enough on its own: another frame type's
    /// payload does not decode as a status, and that must not be reported as a lost status.
    func testOtherFrameTypesAreIgnoredEvenWhenTheirPayloadIsNotAStatus() {
        XCTAssertEqual(classify(#"{"type":"job_event","data":{"job_id":4,"phase":"done"}}"#), .ignored)
    }

    /// `state` is a plain `String` with a default, and Swift's synthesized `Decodable` ignores
    /// property defaults — so a payload that omits it loses the WHOLE frame.
    func testMissingRequiredFieldIsUndecodableAndNamesTheField() {
        guard case .undecodable(let why) = classify(#"{"type":"printer_status","printer_id":1,"data":{"connected":true}}"#)
        else { return XCTFail("expected .undecodable") }
        XCTAssertTrue(why.contains("state"), why)
    }

    /// The port note's scenario: firmware stringifies a numeric that was ported as a strict `Int`.
    func testStringifiedStrictNumericIsUndecodableRatherThanIgnored() {
        let raw = #"{"type":"printer_status","printer_id":1,"data":{"connected":true,"state":"RUNNING","nozzle_rack":[{"id":"0"}]}}"#
        guard case .undecodable(let why) = classify(raw) else { return XCTFail("expected .undecodable") }
        XCTAssertFalse(why.isEmpty)
    }

    func testStatusFrameWithNoPayloadIsUndecodable() {
        guard case .undecodable = classify(#"{"type":"printer_status","printer_id":2}"#) else {
            return XCTFail("expected .undecodable")
        }
    }

    func testGarbageIsUndecodable() {
        guard case .undecodable = classify("not json") else { return XCTFail("expected .undecodable") }
        guard case .undecodable = classify("") else { return XCTFail("expected .undecodable") }
    }

    /// The reason string is logged, so it may carry field NAMES and nothing else.
    func testReasonNeverEchoesThePayload() {
        let raw = #"{"type":"printer_status","printer_id":1,"data":{"connected":true,"state":"RUNNING","nozzle_rack":[{"id":"s3cr3t"}]}}"#
        guard case .undecodable(let why) = classify(raw) else { return XCTFail("expected .undecodable") }
        XCTAssertFalse(why.contains("s3cr3t"), why)
    }

    /// `parse` keeps its old contract: a frame only counts when it carries a usable status.
    func testParseStillYieldsNilForEverythingButAStatus() {
        XCTAssertNil(WsFrame.parse(#"{"type":"pong"}"#))
        XCTAssertNil(WsFrame.parse(#"{"type":"printer_status","printer_id":2}"#))
        XCTAssertNil(WsFrame.parse("not json"))
        XCTAssertNotNil(WsFrame.parse(#"{"type":"printer_status","printer_id":2,"data":{"connected":true,"state":"IDLE"}}"#))
    }
}

/// `Int(Double)` traps rather than degrading, and the inputs come off the wire.
final class SafeIntTests: XCTestCase {

    func testRoundsHalvesAwayFromZero() {
        XCTAssertEqual(SafeInt.rounded(2.5), 3)
        XCTAssertEqual(SafeInt.rounded(-2.5), -3)
        XCTAssertEqual(SafeInt.rounded(2.4), 2)
    }

    func testNilAndNonFiniteBecomeZero() {
        XCTAssertEqual(SafeInt.rounded(nil), 0)
        XCTAssertEqual(SafeInt.rounded(.nan), 0)
        XCTAssertEqual(SafeInt.rounded(.infinity), 0)
        XCTAssertEqual(SafeInt.rounded(-.infinity), 0)
    }

    /// `Double("1e30")` parses, is finite, and is not representable as an `Int`.
    func testOutOfRangeMagnitudesSaturate() {
        XCTAssertEqual(SafeInt.rounded(1e30), .max)
        XCTAssertEqual(SafeInt.rounded(-1e30), .min)
        XCTAssertEqual(SafeInt.truncated(1e30), .max)
        XCTAssertEqual(SafeInt.truncated(-1e30), .min)
    }

    func testTruncationDoesNotRoundUp() {
        XCTAssertEqual(SafeInt.truncated(119.0 / 60), 1)
        XCTAssertEqual(SafeInt.truncated(-1.9), -1)
        XCTAssertEqual(SafeInt.truncated(59.999), 59)
    }
}

/// The two modules on the dashboard's primary render path converted payload `Double`s straight to
/// `Int`, so a stringified NaN or a silly magnitude crashed the app on every status frame.
final class DomainNumericGuardTests: XCTestCase {

    private func status(progress: Double? = nil, ams: [AmsUnitRaw]? = nil) -> PrinterStatus {
        var s = PrinterStatus()
        s.connected = true
        s.state = "RUNNING"
        s.progress = progress.map { LooseNumber($0) }
        s.ams = ams
        return s
    }

    private func tray(_ id: Int, remain: Double) -> AmsTray {
        var t = AmsTray(id: id)
        t.trayType = "PLA"
        t.trayColor = "00AE42FF"
        t.remain = LooseNumber(remain)
        return t
    }

    private func unit(_ id: Int, trays: [AmsTray], dryTime: Double? = nil) -> AmsUnitRaw {
        var u = AmsUnitRaw(id: id)
        u.tray = trays
        u.dryTime = dryTime.map { LooseNumber($0) }
        return u
    }

    // MARK: - Dashboard

    func testProgressSaturatesInsteadOfTrapping() {
        XCTAssertEqual(Dash.present(status(progress: 1e30)).progressInt, .max)
        XCTAssertEqual(Dash.present(status(progress: .nan)).progressInt, 0)
        XCTAssertEqual(Dash.present(status(progress: 42.6)).progressInt, 43)
    }

    func testDurationSurvivesAnUnrepresentableHourCount() {
        XCTAssertEqual(Dash.fmtDuration(1e30), "\(Int.max)h 16m")
        XCTAssertEqual(Dash.fmtDuration(.infinity), "—")
        XCTAssertEqual(Dash.fmtDuration(.nan), "—")
        XCTAssertEqual(Dash.fmtDuration(134), "2h 14m")
    }

    // MARK: - AMS

    func testDryTimeNaNDoesNotTrap() {
        let vm = AmsTopology.present(status(ams: [unit(0, trays: [tray(0, remain: 80)], dryTime: .nan)]))
        XCTAssertEqual(vm.units.first?.dryingMinLeft, 0)
    }

    func testDryTimeMagnitudeSaturates() {
        let vm = AmsTopology.present(status(ams: [unit(0, trays: [tray(0, remain: 80)], dryTime: 1e30)]))
        XCTAssertEqual(vm.units.first?.dryingMinLeft, .max)
    }

    func testNegativeDryTimeStaysClampedAtZero() {
        let vm = AmsTopology.present(status(ams: [unit(0, trays: [tray(0, remain: 80)], dryTime: -5)]))
        XCTAssertEqual(vm.units.first?.dryingMinLeft, 0)
    }

    func testTrayRemainNaNRendersZeroRatherThanCrashing() {
        let vm = AmsTopology.present(status(ams: [unit(0, trays: [tray(0, remain: .nan)])]))
        XCTAssertEqual(vm.slots.first?.pct, "0%")
    }

    func testTrayRemainMagnitudeSaturates() {
        let vm = AmsTopology.present(status(ams: [unit(0, trays: [tray(0, remain: 1e30)])]))
        XCTAssertEqual(vm.slots.first?.pct, "\(Int.max)%")
    }
}

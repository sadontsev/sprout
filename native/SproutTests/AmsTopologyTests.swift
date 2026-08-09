import XCTest
@testable import Sprout

/// AMS topology is the only tray-id math in the app; getting it wrong lights the wrong spool.
final class AmsTopologyTests: XCTestCase {

    private func tray(_ id: Int, type: String? = "PLA", color: String? = "00AE42FF", remain: Double = 80) -> AmsTray {
        var t = AmsTray(id: id)
        t.trayType = type
        t.trayColor = color
        t.remain = LooseNumber(remain)
        return t
    }

    private func unit(_ id: Int, trays: [AmsTray], isHt: Bool = false, serial: String? = nil) -> AmsUnitRaw {
        var u = AmsUnitRaw(id: id)
        u.tray = trays
        u.isAmsHt = isHt ? true : nil
        u.serialNumber = serial
        return u
    }

    // MARK: - Global tray ids

    func testGlobalTrayIdPacksFourPerRegularUnit() {
        XCTAssertEqual(AmsTopology.globalTrayId(unitId: 0, localId: 0), 0)
        XCTAssertEqual(AmsTopology.globalTrayId(unitId: 0, localId: 3), 3)
        XCTAssertEqual(AmsTopology.globalTrayId(unitId: 1, localId: 0), 4)
        XCTAssertEqual(AmsTopology.globalTrayId(unitId: 3, localId: 3), 15)
    }

    /// An AMS HT is a single-spool unit whose id IS its tray id.
    func testHtUnitIdIsItsOwnTrayId() {
        XCTAssertEqual(AmsTopology.globalTrayId(unitId: 128, localId: 0), 128)
        XCTAssertEqual(AmsTopology.globalTrayId(unitId: 135, localId: 0), 135)
    }

    // MARK: - Active slot

    /// The regression: comparing a LOCAL index against `trayNow` lit the HT's tray whenever AMS-1
    /// slot 0 printed.
    func testActiveSlotComparesGlobalIds() {
        var s = PrinterStatus()
        s.connected = true
        s.ams = [unit(0, trays: [tray(0)]), unit(128, trays: [tray(0)], isHt: true)]
        s.trayNow = 0

        let result = AmsTopology.present(s)
        XCTAssertTrue(result.slots[0].active, "AMS 1 slot 0 is global id 0")
        XCTAssertFalse(result.slots[1].active, "the HT is global id 128 and must stay dark")
    }

    func testHtSlotLightsOnItsOwnId() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0)]), unit(128, trays: [tray(0)], isHt: true)]
        s.trayNow = 128
        let result = AmsTopology.present(s)
        XCTAssertFalse(result.slots[0].active)
        XCTAssertTrue(result.slots[1].active)
    }

    func testEmptySlotIsNeverActive() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0, type: nil, color: nil)])]
        s.trayNow = 0
        XCTAssertFalse(AmsTopology.present(s).slots[0].active)
    }

    // MARK: - Labelling

    func testLabelsComeFromStableUnitIdsNotArrayPosition() {
        var s = PrinterStatus()
        // Deliberately out of order — the printer may reorder these.
        s.ams = [unit(1, trays: [tray(0)]), unit(0, trays: [tray(0)])]
        let units = AmsTopology.present(s).units
        XCTAssertEqual(units[0].label, "AMS 2")
        XCTAssertEqual(units[1].label, "AMS 1")
    }

    func testSingleHtIsUnnumbered() {
        var s = PrinterStatus()
        s.ams = [unit(128, trays: [tray(0)], isHt: true)]
        XCTAssertEqual(AmsTopology.present(s).units[0].label, "AMS HT")
    }

    func testMultipleHtsAreNumbered() {
        var s = PrinterStatus()
        s.ams = [unit(128, trays: [tray(0)], isHt: true), unit(129, trays: [tray(0)], isHt: true)]
        let units = AmsTopology.present(s).units
        XCTAssertEqual(units[0].label, "AMS HT 1")
        XCTAssertEqual(units[1].label, "AMS HT 2")
    }

    /// A unit in the 128+ space without the flag is still an HT — classification and counting must
    /// use the same predicate, or two units end up with one identical label.
    func testHighIdWithoutFlagIsStillHt() {
        var s = PrinterStatus()
        s.ams = [unit(128, trays: [tray(0)]), unit(129, trays: [tray(0)], isHt: true)]
        let units = AmsTopology.present(s).units
        XCTAssertEqual(units[0].kind, .ht)
        XCTAssertEqual(units[0].label, "AMS HT 1")
        XCTAssertEqual(units[1].label, "AMS HT 2")
    }

    func testDryCeilingIsPerKind() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0)]), unit(128, trays: [tray(0)], isHt: true)]
        let units = AmsTopology.present(s).units
        XCTAssertEqual(units[0].maxDryTemp, 65, "AMS 2 Pro hardware max")
        XCTAssertEqual(units[1].maxDryTemp, 85, "AMS HT reaches higher")
    }

    func testSerialTailIgnoresPlaceholder() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0)], serial: "N/A"), unit(1, trays: [tray(0)], serial: "AMS0123456789ABCD")]
        let units = AmsTopology.present(s).units
        XCTAssertEqual(units[0].serialTail, "")
        XCTAssertEqual(units[1].serialTail, "ABCD")
    }

    // MARK: - Routing

    func testCompleteMapMeansFixedRouting() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0)]), unit(1, trays: [tray(0)])]
        s.amsExtruderMap = ["0": 0, "1": 1]
        let result = AmsTopology.present(s)
        XCTAssertEqual(result.routing, .fixed)
        XCTAssertEqual(result.units[0].extruder, 0)
        XCTAssertEqual(result.units[1].extruder, 1)
    }

    /// An INCOMPLETE map is itself the tell: Bambuddy omits any unit whose info nibble reads 0xE,
    /// which is exactly what a switch-routed unit reports. The WebSocket omits `filaSwitch`
    /// entirely, so this is the signal that actually fires in the running app.
    func testIncompleteMapMeansSwitchRouting() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0)]), unit(1, trays: [tray(0)]), unit(128, trays: [tray(0)], isHt: true)]
        s.amsExtruderMap = ["0": 0, "128": 1]   // unit 1 can never gain an entry
        let result = AmsTopology.present(s)
        XCTAssertEqual(result.routing, .switch)
        XCTAssertTrue(result.units.allSatisfy { $0.extruder == nil }, "stale residue must not be shown as routing")
    }

    func testInstalledSwitchForcesSwitchRoutingEvenWithACompleteMap() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0)])]
        s.amsExtruderMap = ["0": 0]
        s.filaSwitch = FilaSwitch(installed: true)
        XCTAssertEqual(AmsTopology.present(s).routing, .switch)
    }

    func testSwitchRoutingResolvesPerTrayFromTheTrack() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0), tray(1)])]
        s.filaSwitch = FilaSwitch(installed: true, inSlots: [1, -1], outExtruders: [1, 0xE])
        let slots = AmsTopology.present(s).slots
        XCTAssertNil(slots[0].extruder, "global id 0 is not on a track")
        XCTAssertEqual(slots[1].extruder, 1, "global id 1 is on track 0, which terminates at extruder 1")
    }

    func testNoOutletMarkerIsNotAnExtruder() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0)])]
        s.filaSwitch = FilaSwitch(installed: true, inSlots: [0], outExtruders: [0xE])
        XCTAssertNil(AmsTopology.present(s).slots[0].extruder)
    }

    func testExtruderSideNaming() {
        XCTAssertEqual(AmsTopology.extruderSide(0), "Right")
        XCTAssertEqual(AmsTopology.extruderSide(1), "Left")
        XCTAssertEqual(AmsTopology.extruderSide(nil), "")
    }

    // MARK: - Slot presentation

    func testEmptySlotHasNoColourAndNoPercentage() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0, type: nil, color: nil)])]
        let slot = AmsTopology.present(s).slots[0]
        XCTAssertTrue(slot.empty)
        XCTAssertEqual(slot.label, "Empty")
        XCTAssertNil(slot.color)
        XCTAssertEqual(slot.pct, "—")
    }

    /// The unset-colour sentinel must not become black — it once beat a spool's real colour.
    func testUnsetColourSentinelIsNil() {
        var s = PrinterStatus()
        s.ams = [unit(0, trays: [tray(0, color: "00000000")])]
        let slot = AmsTopology.present(s).slots[0]
        XCTAssertFalse(slot.empty, "there is filament, we just don't know its colour")
        XCTAssertNil(slot.color)
    }

    func testEveryUnitContributesSlots() {
        var s = PrinterStatus()
        s.ams = [
            unit(0, trays: (0..<4).map { tray($0) }),
            unit(1, trays: (0..<4).map { tray($0) }),
            unit(128, trays: [tray(0)], isHt: true),
        ]
        let result = AmsTopology.present(s)
        XCTAssertEqual(result.units.count, 3)
        XCTAssertEqual(result.slots.count, 9, "reading ams[0] alone would hide 5 of 9 slots")
        XCTAssertEqual(result.slots.map(\.globalId), [0, 1, 2, 3, 4, 5, 6, 7, 128])
    }

    func testNoAmsYieldsNothing() {
        let result = AmsTopology.present(PrinterStatus())
        XCTAssertTrue(result.units.isEmpty)
        XCTAssertTrue(result.slots.isEmpty)
        XCTAssertEqual(result.routing, .fixed)
    }

    func testTrayRefsKeepRawValuesForMatching() {
        var s = PrinterStatus()
        s.ams = [unit(1, trays: [tray(2, type: "PETG-CF", color: "565656FF")])]
        let refs = AmsTopology.trayRefs(s)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].globalId, 6)
        XCTAssertEqual(refs[0].trayType, "PETG-CF")
        XCTAssertEqual(refs[0].trayColor, "565656FF", "preset matching needs the unformatted value")
    }
}

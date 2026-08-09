import Foundation
import XCTest
@testable import Sprout

final class LanModeTests: XCTestCase {

    /// A status that carries nothing but the flag under test.
    private func status(_ developerMode: Bool?) -> PrinterStatus {
        var s = PrinterStatus()
        s.developerMode = developerMode
        return s
    }

    private let blocked: [ActionId] = [
        .pause, .resume, .speed, .amsLoad, .amsUnload, .dryStart, .dryStop, .startPrint, .printAgain,
    ]
    private let allowed: [ActionId] = [
        .stop, .light, .camera, .plug, .plateCleared, .maintenance, .queueRemove,
    ]

    // MARK: - mode(from:) — tri-state, because absence is not "off"

    func testReadsAnExplicitBoolean() {
        XCTAssertEqual(Lan.mode(from: status(true)), .on)
        XCTAssertEqual(Lan.mode(from: status(false)), .off)
    }

    func testTreatsAbsentOrNoStatusAsUnknownNeverOff() {
        // A gate that reads absence as "off" greys out the whole UI on every cold start, and —
        // worse — the field is missing from the WebSocket payload entirely, which is the app's
        // primary feed.
        XCTAssertEqual(Lan.mode(from: status(nil)), .unknown)
        XCTAssertEqual(Lan.mode(from: nil), .unknown)
    }

    func testAnOtherwisePopulatedStatusWithoutTheFlagIsStillUnknown() {
        // The WebSocket feed sends a full, healthy-looking status with `developer_mode` simply
        // absent. Nothing else in the payload may be taken as evidence either way.
        var s = PrinterStatus()
        s.connected = true
        s.state = "RUNNING"
        s.progress = 42
        XCTAssertEqual(Lan.mode(from: s), .unknown)
    }

    // MARK: - isBlocked

    func testBlocksEveryPrintCommandWhenDeveloperModeIsOff() {
        for a in blocked {
            XCTAssertTrue(Lan.isBlocked(a, .off), "\(a.rawValue) must be blocked when Developer Mode is off")
        }
    }

    func testNeverBlocksTheEmergencyStop() {
        // A dead grey Stop on a print that is spaghettifying is actively dangerous. A Stop that
        // might fail is strictly better than one that cannot be pressed.
        for m in LanMode.allCases {
            XCTAssertFalse(Lan.isBlocked(.stop, m), "stop must never be blocked (mode \(m.rawValue))")
        }
    }

    func testNeverBlocksTheThingsThatDoNotGoThroughTheVerifiedMqttTopic() {
        for a in allowed {
            XCTAssertFalse(Lan.isBlocked(a, .off), "\(a.rawValue) does not go through the verified topic")
        }
    }

    func testBlocksNothingWhileTheModeIsOnOrNotYetKnown() {
        for a in blocked + allowed {
            XCTAssertFalse(Lan.isBlocked(a, .on), "\(a.rawValue) blocked while Developer Mode is on")
            XCTAssertFalse(Lan.isBlocked(a, .unknown), "\(a.rawValue) blocked while the mode is unknown")
        }
        XCTAssertEqual(Lan.blockedActions(.unknown), [])
        XCTAssertEqual(Lan.blockedActions(.on), [])
    }

    func testTheBlockedSetIsExactlyThePrintCommandFamily() {
        XCTAssertEqual(
            Lan.blockedActions(.off).map(\.rawValue).sorted(),
            blocked.map(\.rawValue).sorted()
        )
    }

    func testTheLightIsAllowedItIsLedctrlNotAPrintCommand() {
        XCTAssertFalse(Lan.isBlocked(.light, .off))
    }

    // MARK: - lockedStyle

    func testDimsALockedControlAndLeavesAnAvailableOneUntouched() {
        XCTAssertEqual(Lan.lockedStyle(true), Lan.lockedOpacity)
        XCTAssertNil(Lan.lockedStyle(false))
    }

    func testReturnsNilNotOneSoItComposesWithoutClobbering() {
        // `lockedStyle(false) ?? x` must be a no-op; a 1 would override a caller's own opacity
        // (e.g. the dryer buttons' `busy ? 0.5 : 1`).
        XCTAssertEqual(Lan.lockedStyle(false) ?? 0.5, 0.5)
        XCTAssertEqual(Lan.lockedStyle(true) ?? 0.5, Lan.lockedOpacity)
    }

    func testTheDimIsTheOneMeasuredValue() {
        XCTAssertEqual(Lan.lockedOpacity, 0.4, accuracy: 0.0001)
    }

    // MARK: - Swift-specific invariants

    func testBlockedIsOrderedAndFreeOfDuplicates() {
        // `blocked` is an array feeding a Set; a duplicate would make the two disagree about count
        // and make any enumeration of locked controls render one twice.
        XCTAssertEqual(Set(Lan.blocked).count, Lan.blocked.count)
        // Declaration order is the contract — Set iteration order is not stable across runs.
        XCTAssertEqual(Lan.blockedActions(.off), blocked)
    }

    func testEveryActionIdIsClassifiedAsBlockedOrAllowed() {
        // Adding a case to ActionId without deciding whether the printer refuses it is the bug this
        // catches: an ungated action silently defaults to "allowed" and lies to the user.
        XCTAssertEqual(Set(blocked + allowed), Set(ActionId.allCases))
        XCTAssertTrue(Set(blocked).isDisjoint(with: Set(allowed)))
    }

    func testActionIdRawValuesAreTheStableNames() {
        XCTAssertEqual(
            ActionId.allCases.map(\.rawValue),
            [
                "pause", "resume", "stop", "light", "speed",
                "amsLoad", "amsUnload", "dryStart", "dryStop",
                "startPrint", "plateCleared", "printAgain",
                "plug", "camera", "maintenance", "queueRemove",
            ]
        )
        XCTAssertEqual(ActionId(rawValue: "amsUnload"), .amsUnload)
        XCTAssertNil(ActionId(rawValue: "amsunload"), "the names are case-sensitive")
    }

    func testLanModeRawValues() {
        XCTAssertEqual(LanMode.allCases.map(\.rawValue), ["on", "off", "unknown"])
    }

    // MARK: - Copy

    func testBannerAndHintCopy() {
        XCTAssertEqual(Lan.bannerTitle, "Printer controls are locked")
        XCTAssertEqual(
            Lan.bannerBody,
            "This printer won't accept commands until LAN Developer Mode is on. Monitoring, the camera and your library still work."
        )
        XCTAssertEqual(
            Lan.blockedHint,
            "Turn on LAN Developer Mode on the printer (Settings → Network), then re-enter its new access code in this app."
        )
        XCTAssertEqual(Lan.helpTitle, "Turn on LAN Developer Mode")
    }

    func testHelpBodyLineStructure() {
        // A multi-line literal is one stray space away from shipping the source file's indentation
        // into the help sheet, and one stray newline away from a trailing blank line.
        let lines = Lan.helpBody.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 8)
        XCTAssertTrue(lines[0].hasPrefix("Your printer reports status, streams the camera and accepts files,"))
        XCTAssertTrue(lines[0].hasSuffix("Its firmware requires signed commands unless Developer Mode is on."))
        XCTAssertEqual(lines[1], "")
        XCTAssertEqual(lines[2], "On the printer:")
        XCTAssertEqual(lines[3], "1. Settings → Network → LAN Only Mode.")
        XCTAssertEqual(lines[4], "2. Turn on Developer Mode and confirm.")
        XCTAssertEqual(lines[5], "3. The printer shows a NEW access code.")
        XCTAssertEqual(lines[6], "")
        XCTAssertEqual(
            lines[7],
            "Then update the access code in Bambuddy, and this app will be able to control the printer again."
        )
        XCTAssertFalse(lines.contains { $0.hasPrefix(" ") }, "indentation leaked out of the literal")
        XCTAssertFalse(Lan.helpBody.hasSuffix("\n"))
    }

    func testHelpBodyNamesEveryBlockedControlFamily() {
        // The explainer promises exactly what the gate refuses; if the two drift the user is told
        // the wrong thing about their own printer.
        for phrase in ["pause", "resume", "speed", "AMS", "drying", "starting a print"] {
            XCTAssertTrue(Lan.helpBody.contains(phrase), "help body no longer mentions \(phrase)")
        }
    }
}

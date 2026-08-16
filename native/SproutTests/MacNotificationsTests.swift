#if os(macOS)
import Foundation
import UserNotifications
import XCTest
@testable import Sprout

/// The Mac's local print alerts (spec 1d).
///
/// macOS-only for the same reason the Live Activity suites are iOS-only: the subject is. Every case
/// here is an EDGE — something that happens once, hours apart, on real hardware — which is exactly
/// the class of logic that ships broken and is never noticed, because "no notification" and "no
/// event" look identical from the outside.
///
/// The controller itself is not exercised: it needs `UNUserNotificationCenter` and a live
/// `AppModel`. Everything that decides *whether* to notify is pure and lives here.
final class MacNotificationsTests: XCTestCase {

    // MARK: - Fixtures

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func sample(
        _ kind: DashKind,
        paused: Bool = false,
        job: String = "benchy.3mf",
        bed: Double = 0,
        error: String? = nil,
        dryers: [MacNotifySample.Dryer] = [],
        printerId: Int = 1,
        name: String = "H2C"
    ) -> MacNotifySample {
        MacNotifySample(
            printerId: printerId, printerName: name, kind: kind, isPaused: paused,
            jobName: job, bedC: bed, printErrorText: error, dryers: dryers
        )
    }

    /// Run a sequence of samples through the rules, returning every event in order.
    private func run(
        _ steps: [(MacNotifySample, Date)],
        state: MacWatchState = MacWatchState()
    ) -> (events: [MacNotifyEvent], state: MacWatchState) {
        var carried = state
        var out: [MacNotifyEvent] = []
        for (sample, now) in steps {
            let result = MacNotifyRules.step(sample, state: carried, now: now)
            out.append(contentsOf: result.events)
            carried = result.state
        }
        return (out, carried)
    }

    /// Only the events of one kind. Several rules fire on the same poll — a print going idle both
    /// "stopped" and starts the plate cooling — so a test about one of them says so.
    private func only(_ kind: MacNotifyKind, _ events: [MacNotifyEvent]) -> [MacNotifyEvent] {
        events.filter { $0.kind == kind }
    }

    // MARK: - The first observation is always silent

    /// Attaching to a printer that finished an hour ago must not announce it, and neither must the
    /// reconnect that follows a Save in Settings. `lastKind == nil` is what buys that, and it is
    /// the single most load-bearing line in the rules.
    func testFirstObservationIsSilentForEveryKind() {
        for kind in [DashKind.idle, .live, .complete, .error] {
            let (events, state) = run([(sample(kind), t0)])
            XCTAssertTrue(events.isEmpty, "\(kind) announced itself on first sight")
            XCTAssertEqual(state.lastKind, kind)
        }
    }

    /// A paused printer observed for the first time is also silent — the same argument.
    func testFirstObservationOfAPausedPrinterIsSilent() {
        let (events, state) = run([(sample(.live, paused: true), t0)])
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state.wasPaused, true)
    }

    // MARK: - Kind edges

    func testFinishFires() {
        let (events, _) = run([
            (sample(.live), at(0)),
            (sample(.complete), at(1)),
        ])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .finished)
        XCTAssertEqual(events.first?.id, "1:complete")
        XCTAssertEqual(events.first?.printerId, 1)
        XCTAssertTrue(events.first?.title.contains("H2C") == true)
        XCTAssertEqual(events.first?.message, "benchy.3mf")
    }

    func testErrorFiresAndNamesThePrinterErrorNumber() {
        let (events, _) = run([
            (sample(.live), at(0)),
            (sample(.error, error: "8019"), at(1)),
        ])
        XCTAssertEqual(events.map(\.kind), [.problem])
        XCTAssertTrue(events[0].message.contains("8019"), events[0].message)
    }

    /// A live print that goes IDLE ended WITHOUT completing — cancelled, or given up on by the
    /// printer. This is the alert you most want while away, and a complete/error-only rule cannot
    /// see it at all.
    func testStoppedFiresOnLiveToIdle() {
        let (events, _) = run([
            (sample(.live), at(0)),
            (sample(.idle, job: ""), at(1)),
        ])
        XCTAssertEqual(events.map(\.kind), [.stopped])
    }

    /// The job name has to survive the job. Going idle takes `subtaskName` with it, so the one
    /// alert that most needs to name the print is the one that would otherwise say "your print".
    func testStoppedRemembersTheJobNameTheJobTookWithIt() {
        let (events, _) = run([
            (sample(.live, job: "dragon-body.3mf"), at(0)),
            (sample(.idle, job: ""), at(1)),
        ])
        XCTAssertTrue(events[0].message.contains("dragon-body.3mf"), events[0].message)
    }

    /// `complete -> idle` is the plate being cleared, not a job dying. Announcing it would follow
    /// every successful print with "print stopped".
    func testCompleteToIdleIsSilent() {
        let (events, _) = run([
            (sample(.live), at(0)),
            (sample(.complete), at(1)),
            (sample(.idle, job: ""), at(2)),
        ])
        XCTAssertEqual(events.map(\.kind), [.finished])
    }

    /// A WebSocket blip must never be read as a print ending. `offline`/`connecting` are the
    /// ABSENCE of a state, so they neither fire nor overwrite what was last actually known.
    func testOfflineBlipNeitherFiresNorForgets() {
        let (events, state) = run([
            (sample(.live), at(0)),
            (sample(.offline), at(1)),
            (sample(.connecting), at(2)),
            (sample(.live), at(3)),
        ])
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(state.lastKind, .live)
    }

    /// …and coming back from a blip to a FINISH still fires, because the pre-blip state was kept.
    func testFinishAfterABlipStillFires() {
        let (events, _) = run([
            (sample(.live), at(0)),
            (sample(.offline), at(1)),
            (sample(.complete), at(2)),
        ])
        XCTAssertEqual(events.map(\.kind), [.finished])
    }

    // MARK: - The pause edge

    /// PAUSE does not change `kind` — `Dash.present` maps it to `.live` — so a kind-edge rule
    /// cannot see it. This is the alert that matters most: an AI-detection halt and a filament
    /// runout both stop the print and wait for a human.
    func testPauseFiresOnItsOwnEdge() {
        let (events, _) = run([
            (sample(.live), at(0)),
            (sample(.live, paused: true), at(1)),
        ])
        XCTAssertEqual(events.map(\.kind), [.problem])
        XCTAssertEqual(events[0].id, "1:paused")
    }

    func testPauseCarriesThePrinterErrorWhenThereIsOne() {
        let (events, _) = run([
            (sample(.live), at(0)),
            (sample(.live, paused: true, error: "0700"), at(1)),
        ])
        XCTAssertTrue(events[0].message.contains("0700"), events[0].message)
    }

    /// Staying paused is not a new event. Only the crossing is.
    func testStayingPausedDoesNotRepeatImmediately() {
        let (events, _) = run([
            (sample(.live), at(0)),
            (sample(.live, paused: true), at(1)),
            (sample(.live, paused: true), at(2)),
            (sample(.live, paused: true), at(3)),
        ])
        XCTAssertEqual(events.count, 1)
    }

    /// One banner is a single point of failure for a printer that is halted and waiting on a
    /// human, so it is re-announced at 10/30/60 minutes — and then goes quiet rather than nagging.
    func testPauseRemindersFireAtTenThirtySixtyThenStop() {
        var steps: [(MacNotifySample, Date)] = [(sample(.live), at(0)), (sample(.live, paused: true), at(1))]
        for minute in stride(from: 2.0, through: 130.0, by: 1.0) {
            steps.append((sample(.live, paused: true), at(minute)))
        }
        let (events, _) = run(steps)
        // The pause itself, then exactly three reminders — never a fourth.
        XCTAssertEqual(events.map(\.id), ["1:paused", "1:paused:10", "1:paused:30", "1:paused:60"])
    }

    /// Resuming and pausing again is a new incident, not a continuation of the old one.
    func testResumeThenPauseAgainFiresAndResetsTheReminders() {
        var steps: [(MacNotifySample, Date)] = [
            (sample(.live), at(0)),
            (sample(.live, paused: true), at(1)),
            (sample(.live), at(2)),
            (sample(.live, paused: true), at(3)),
        ]
        for minute in stride(from: 4.0, through: 20.0, by: 1.0) {
            steps.append((sample(.live, paused: true), at(minute)))
        }
        let (events, state) = run(steps)
        XCTAssertEqual(events.map(\.id), ["1:paused", "1:paused", "1:paused:10"])
        XCTAssertEqual(state.pauseRemindersSent, 1)
    }

    // MARK: - The plate-cooldown gate

    /// The whole reason this gate exists rather than reading `CooldownStore.vm.phase`: a printer
    /// that has been cold and idle for a week satisfies "the plate is cool" on every single poll.
    /// Without the ARM step it would announce itself forever.
    func testAnIdleColdPrinterNeverAnnouncesAPlate() {
        var steps: [(MacNotifySample, Date)] = []
        for minute in stride(from: 0.0, through: 60.0, by: 1.0) {
            steps.append((sample(.idle, job: "", bed: 22), at(minute)))
        }
        let (events, _) = run(steps)
        XCTAssertTrue(events.isEmpty)
    }

    /// Armed by a hot bed during a print, then fired once when the bed crosses the threshold.
    func testPlateCoolFiresOnceAfterAHotPrint() {
        var steps: [(MacNotifySample, Date)] = [(sample(.live, bed: 60), at(0))]
        for (i, bed) in [50.0, 44.0, 38.0, 34.0, 33.0, 32.0].enumerated() {
            steps.append((sample(.complete, job: "benchy.3mf", bed: bed), at(Double(i + 1))))
        }
        let cool = only(.plateCool, run(steps).events)
        XCTAssertEqual(cool.count, 1)
        XCTAssertEqual(cool[0].id, "1:cool")
        XCTAssertTrue(cool[0].title.contains("plate is cool"), cool[0].title)
        // Not urgent: a cool plate is not something to be woken by.
        XCTAssertFalse(cool[0].urgent)
    }

    /// A print that never got the bed above the threshold cannot arm the gate — otherwise a
    /// cold-bed print (or a printer merely idling warm) would set up a spurious announcement.
    func testACoolPrintDoesNotArmTheGate() {
        var steps: [(MacNotifySample, Date)] = [(sample(.live, bed: 30), at(0))]
        for minute in stride(from: 1.0, through: 10.0, by: 1.0) {
            steps.append((sample(.complete, bed: 28), at(minute)))
        }
        XCTAssertTrue(only(.plateCool, run(steps).events).isEmpty)
    }

    /// A plate approaches room temperature asymptotically and cannot cross it, so on a warm day the
    /// 35 °C threshold may simply never arrive. Without the plateau branch the user would be told
    /// nothing at all, with nothing to diagnose.
    func testPlateStalledAboveTheThresholdStillAnnouncesItself() {
        var steps: [(MacNotifySample, Date)] = [(sample(.live, bed: 60), at(0))]
        // Settles at 38 °C in a warm room and stops falling.
        for minute in stride(from: 1.0, through: 20.0, by: 1.0) {
            steps.append((sample(.complete, bed: 38.2), at(minute)))
        }
        let cool = only(.plateCool, run(steps).events)
        XCTAssertEqual(cool.count, 1)
        XCTAssertTrue(cool[0].title.contains("stopped cooling"), cool[0].title)
    }

    /// A bed reading of 0 means "no data" far more often than "the plate is frozen" —
    /// `temperatures` is nullable and a missing field rounds to 0 upstream. Firing on it would
    /// announce a cool plate for a printer that is not reporting one.
    func testAZeroBedReadingIsNoDataNotAColdPlate() {
        var steps: [(MacNotifySample, Date)] = [(sample(.live, bed: 60), at(0))]
        for minute in stride(from: 1.0, through: 30.0, by: 1.0) {
            steps.append((sample(.complete, bed: 0), at(minute)))
        }
        XCTAssertTrue(only(.plateCool, run(steps).events).isEmpty)
    }

    /// Fires once per print, then re-arms on the next one — not once per install.
    func testPlateCoolReArmsForTheNextPrint() {
        let steps: [(MacNotifySample, Date)] = [
            (sample(.live, bed: 60), at(0)),
            (sample(.complete, bed: 30), at(1)),     // fires
            (sample(.complete, bed: 29), at(2)),     // silent — already fired
            (sample(.live, bed: 62), at(3)),         // next print re-arms
            (sample(.complete, bed: 33), at(4)),     // fires again
        ]
        XCTAssertEqual(only(.plateCool, run(steps).events).count, 2)
    }

    /// The gate is a state machine over values, so its own contract is asserted directly: firing
    /// disarms AND drops the sample history, or the next print's first reading would be compared
    /// against the last print's cooldown.
    func testFiringTheCoolGateDisarmsItAndDropsTheHistory() {
        let armed = MacCoolState(armed: true, fired: false, seen: [BedSample(t: t0, c: 40)])
        let (action, next) = MacNotifyRules.coolStep(
            printing: false, bedC: 34, thresholdC: 35, state: armed, now: at(1)
        )
        XCTAssertEqual(action, .ready)
        XCTAssertFalse(next.armed)
        XCTAssertTrue(next.fired)
        XCTAssertTrue(next.seen.isEmpty)
        // …and the caller's copy is untouched, because nothing here mutates its input.
        XCTAssertEqual(armed.seen.count, 1)
    }

    // MARK: - Drying

    /// A cycle counting down to zero on its own is worth announcing.
    func testDryingFinishedFiresOnANaturalRunOut() {
        let (events, _) = run([
            (sample(.idle, job: "", dryers: [.init(unitId: 0, minutesLeft: 5, filament: "PETG")]), at(0)),
            (sample(.idle, job: "", dryers: [.init(unitId: 0, minutesLeft: 0, filament: "")]), at(1)),
        ])
        XCTAssertEqual(events.map(\.kind), [.dryingDone])
        XCTAssertEqual(events[0].id, "1:dry:0")
        // The unit clears `dry_filament` the moment the cycle ends, so the name has to come from
        // what was captured while it ran.
        XCTAssertTrue(events[0].message.contains("PETG"), events[0].message)
    }

    /// Falling to zero from a long time remaining is someone pressing stop. They already know.
    func testAManuallyStoppedCycleIsSilent() {
        let (events, _) = run([
            (sample(.idle, job: "", dryers: [.init(unitId: 0, minutesLeft: 240, filament: "PETG")]), at(0)),
            (sample(.idle, job: "", dryers: [.init(unitId: 0, minutesLeft: 0, filament: "")]), at(1)),
        ])
        XCTAssertTrue(events.isEmpty)
    }

    /// First sight of an idle dryer is not "it just finished".
    func testFirstSightOfAnIdleDryerIsSilent() {
        let (events, _) = run([
            (sample(.idle, job: "", dryers: [.init(unitId: 0, minutesLeft: 0, filament: "")]), at(0)),
        ])
        XCTAssertTrue(events.isEmpty)
    }

    /// Three drying-capable units are fitted, so concurrent cycles are ordinary rather than
    /// theoretical — a per-printer key would hide the second one entirely.
    func testConcurrentDryingCyclesAreTrackedPerUnit() {
        let (events, _) = run([
            (sample(.idle, job: "", dryers: [
                .init(unitId: 0, minutesLeft: 4, filament: "PLA"),
                .init(unitId: 128, minutesLeft: 6, filament: "PA-CF"),
            ]), at(0)),
            (sample(.idle, job: "", dryers: [
                .init(unitId: 0, minutesLeft: 0, filament: ""),
                .init(unitId: 128, minutesLeft: 3, filament: "PA-CF"),
            ]), at(1)),
            (sample(.idle, job: "", dryers: [
                .init(unitId: 0, minutesLeft: 0, filament: ""),
                .init(unitId: 128, minutesLeft: 0, filament: ""),
            ]), at(2)),
        ])
        XCTAssertEqual(events.map(\.id), ["1:dry:0", "1:dry:128"])
        XCTAssertTrue(events[1].message.contains("PA-CF"), events[1].message)
    }

    // MARK: - The sample adapter

    /// The one place that knows the wire shape.
    func testSampleReadsWhatTheRulesNeedOffTheStatus() {
        var status = PrinterStatus()
        status.connected = true
        status.state = "PAUSE"
        status.subtaskName = "gridfinity.3mf"
        // NO `printError` here. `Dash.present` tests `printError != 0` BEFORE it tests the state
        // string, so a paused print carrying an error is `.error` — correctly: a print that has
        // failed has failed, whatever `state` still says. Setting both and asserting `.live` was
        // this test claiming a precedence the domain does not have. `printErrorText` has its own
        // case below, which is where that field belongs.
        var temps = Temperatures()
        temps.bed = 47.5
        status.temperatures = temps
        status.ams = [AmsUnitRaw(id: 0, dryTime: 12, dryFilament: "PLA")]

        let built = MacNotifySample(printerId: 3, printerName: "H2C", vm: Dash.present(status), status: status)
        // A PAUSE is `.live` + isPaused — the whole reason the pause edge is separate.
        XCTAssertEqual(built.kind, .live)
        XCTAssertTrue(built.isPaused)
        XCTAssertEqual(built.jobName, "gridfinity.3mf")
        XCTAssertEqual(built.bedC, 47.5)
        XCTAssertEqual(built.dryers, [MacNotifySample.Dryer(unitId: 0, minutesLeft: 12, filament: "PLA")])
    }

    /// A zero `print_error` means "no error" and must not decorate a banner with "error 0".
    func testPrintErrorTextTreatsZeroAndNonsenseAsNoError() {
        XCTAssertNil(MacNotifySample.printErrorText(nil))
        XCTAssertNil(MacNotifySample.printErrorText(LooseNumber(0)))
        XCTAssertNil(MacNotifySample.printErrorText(LooseNumber(Double.nan)))
        XCTAssertNil(MacNotifySample.printErrorText(LooseNumber(Double.infinity)))
        XCTAssertEqual(MacNotifySample.printErrorText(LooseNumber(8019)), "8019")
    }

    /// An unreachable printer classifies as `.offline`, which the rules ignore outright.
    func testSampleOfADisconnectedPrinterIsOffline() {
        let status = PrinterStatus()   // `connected` defaults to false
        let built = MacNotifySample(printerId: 1, printerName: "H2C", vm: Dash.present(status), status: status)
        XCTAssertEqual(built.kind, .offline)
    }

    // MARK: - Preferences

    /// `UserDefaults.bool(forKey:)` answers `false` for a key nobody has written, which is a
    /// DIFFERENT question from "the user switched this off". Reading one as the other would leave
    /// a fresh install silent until all five switches were flipped twice.
    func testAnUnsetToggleDefaultsToOn() throws {
        let name = "sprout.tests.notify.unset"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let prefs = MacNotifyPrefs.load(defaults)
        for kind in MacNotifyKind.allCases {
            XCTAssertTrue(prefs.isEnabled(kind), "\(kind) defaulted to off")
        }
    }

    func testAnExplicitlyDisabledToggleIsOff() throws {
        let name = "sprout.tests.notify.explicit"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defaults.set(false, forKey: MacNotifyKind.dryingDone.defaultsKey)
        defaults.set(true, forKey: MacNotifyKind.finished.defaultsKey)

        let prefs = MacNotifyPrefs.load(defaults)
        XCTAssertFalse(prefs.isEnabled(.dryingDone))
        XCTAssertTrue(prefs.isEnabled(.finished))
        XCTAssertTrue(prefs.isEnabled(.problem))   // still unset, still on
        defaults.removePersistentDomain(forName: name)
    }

    /// The pane's `@AppStorage` and `MacNotifyPrefs.load` must key on the same strings. A drift
    /// here is silent in both directions — the switch moves and no alert changes — so the literals
    /// are pinned.
    func testDefaultsKeysAreStableAndDistinct() {
        XCTAssertEqual(MacNotifyKind.finished.defaultsKey, "mac.notify.finished")
        XCTAssertEqual(MacNotifyKind.stopped.defaultsKey, "mac.notify.stopped")
        XCTAssertEqual(MacNotifyKind.problem.defaultsKey, "mac.notify.problem")
        XCTAssertEqual(MacNotifyKind.plateCool.defaultsKey, "mac.notify.plateCool")
        XCTAssertEqual(MacNotifyKind.dryingDone.defaultsKey, "mac.notify.dryingDone")
        XCTAssertEqual(Set(MacNotifyKind.allCases.map(\.defaultsKey)).count, MacNotifyKind.allCases.count)
    }

    /// Every toggle names the observation behind it — that is what stops a switch quietly becoming
    /// a switch for something adjacent, which is how the "Filament ran out" toggle this replaced
    /// came to be gated on nothing at all.
    func testEveryToggleHasALabelAndStatesWhatItIsGatedOn() {
        for kind in MacNotifyKind.allCases {
            XCTAssertFalse(kind.label.isEmpty, "\(kind) has no label")
            XCTAssertFalse(kind.gatedOn.isEmpty, "\(kind) does not say what it watches")
        }
        XCTAssertEqual(Set(MacNotifyKind.allCases.map(\.label)).count, MacNotifyKind.allCases.count)
    }

    /// Every kind the rules can actually emit has a toggle, and every toggle has a kind that can
    /// reach it. A toggle with no reachable event is the bug this file replaced.
    func testEveryToggleIsReachableFromARealEdge() {
        let steps: [(MacNotifySample, Date)] = [
            (sample(.live, bed: 60), at(0)),
            (sample(.live, paused: true, bed: 60), at(1)),                       // problem
            (sample(.live, bed: 60), at(2)),
            (sample(.complete, bed: 60), at(3)),                                 // finished
            (sample(.live, bed: 60), at(4)),
            (sample(.idle, job: "", bed: 30), at(5)),                            // stopped + plateCool
            (sample(.idle, job: "", bed: 30,
                    dryers: [.init(unitId: 0, minutesLeft: 3, filament: "PLA")]), at(6)),
            (sample(.idle, job: "", bed: 30,
                    dryers: [.init(unitId: 0, minutesLeft: 0, filament: "")]), at(7)),   // dryingDone
        ]
        XCTAssertEqual(Set(run(steps).events.map(\.kind)), Set(MacNotifyKind.allCases))
    }

    // MARK: - Permission wording

    /// A pane that shows nothing when permission was refused leaves someone believing alerts are
    /// on. The wording is the feature, so it is asserted.
    func testAuthorizationAdviceOffersTheRightRouteForEachState() {
        let undecided = MacNotifyAuthorization.advice(.notDetermined)
        XCTAssertTrue(undecided.canAsk)
        XCTAssertFalse(undecided.willBeSeen)

        // macOS shows its prompt exactly once, so a denied app must NOT offer a button that
        // silently does nothing — the only route left is System Settings.
        let denied = MacNotifyAuthorization.advice(.denied)
        XCTAssertFalse(denied.canAsk)
        XCTAssertTrue(denied.canOpenSettings)
        XCTAssertFalse(denied.willBeSeen)

        let allowed = MacNotifyAuthorization.advice(.authorized)
        XCTAssertFalse(allowed.canAsk)
        XCTAssertTrue(allowed.willBeSeen)

        // Provisional IS delivered — quietly. Reporting it as "off" would send someone hunting for
        // a fault that is not there.
        let quiet = MacNotifyAuthorization.advice(.provisional)
        XCTAssertTrue(quiet.willBeSeen)
        XCTAssertNotEqual(quiet.label, allowed.label)
    }

    func testEveryAuthorizationStateSaysSomething() {
        let statuses: [UNAuthorizationStatus] = [.notDetermined, .denied, .authorized, .provisional]
        for status in statuses {
            let advice = MacNotifyAuthorization.advice(status)
            XCTAssertFalse(advice.label.isEmpty)
            XCTAssertFalse(advice.detail.isEmpty)
        }
    }
}
#endif

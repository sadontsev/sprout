#if os(macOS)
// The Mac's answer to the iOS Live Activity + push banners (spec 1d).
//
// macOS has no ActivityKit, and — for the reason spelled out under `MacNotificationController` —
// it also cannot receive the REMOTE banners Trellis pushes to the iPhone. What it can do is watch
// the printer over the connection the app already holds and post a `UNUserNotification` itself.
// That is strictly less than iOS gets, and the Notifications pane says so in those words rather
// than letting someone discover it by not being told their print finished.
//
// Everything above `MacNotificationController` is PURE: values in, values out, no clock of its own
// and no UserNotifications types. That is deliberate — the whole subsystem is edge detection, and
// an edge detector that can only be exercised by running a printer for two hours is an edge
// detector nobody ever checks.
import Foundation
import Observation
import OSLog
import UserNotifications

let macNotifyLog = Logger(subsystem: "com.mvks5.bambu", category: "mac-notify")

// MARK: - What Sprout can tell you about

/// One kind of alert, which is also exactly one toggle in the Notifications pane.
///
/// One enum for both halves on purpose. The pane this replaced carried a **"Filament ran out"**
/// toggle that was wired to nothing at all — there is no filament-runout state on the wire; the
/// printer reports a runout as a PAUSE, exactly like an AI-detection halt and exactly like someone
/// pressing pause on the machine. A switch for a condition the app cannot observe is this
/// codebase's recurring bug in its purest form, so the toggle is gone and `.problem` — gated on the
/// pause edge that a runout actually produces — is what stands in its place.
enum MacNotifyKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    /// The job reached FINISH.
    case finished
    /// A running job went IDLE without finishing — cancelled, or aborted by the printer.
    case stopped
    /// The printer paused, halted or failed. A filament runout arrives here.
    case problem
    /// The plate has come down far enough to lift the print off.
    case plateCool
    /// An AMS drying cycle ran to its end.
    case dryingDone

    var id: String { rawValue }

    /// The `UserDefaults` keys, written out rather than derived.
    ///
    /// Derived keys are one typo away from a toggle that writes somewhere nothing reads, and that
    /// failure is silent in both directions — the switch moves and no alert changes. The pane's
    /// `@AppStorage` and `MacNotifyPrefs.load` both come here.
    enum Key {
        static let finished = "mac.notify.finished"
        static let stopped = "mac.notify.stopped"
        static let problem = "mac.notify.problem"
        static let plateCool = "mac.notify.plateCool"
        static let dryingDone = "mac.notify.dryingDone"
    }

    var defaultsKey: String {
        switch self {
        case .finished: Key.finished
        case .stopped: Key.stopped
        case .problem: Key.problem
        case .plateCool: Key.plateCool
        case .dryingDone: Key.dryingDone
        }
    }

    /// The toggle's label.
    var label: String {
        switch self {
        case .finished: "Print finished"
        case .stopped: "Print stopped before finishing"
        case .problem: "Print paused, halted or failed"
        case .plateCool: "Plate is cool enough to lift the print off"
        case .dryingDone: "Drying finished"
        }
    }

    /// What the app actually watches to decide this fired, in the user's words.
    ///
    /// Shown under each toggle. A switch that names its own evidence cannot quietly become a switch
    /// for something adjacent — which is how "View layers" came to mean "was this prepared by a
    /// slicer" when the question was "does this have toolpaths".
    var gatedOn: String {
        switch self {
        case .finished: "The printer reports FINISH."
        case .stopped: "A running job goes idle without reaching FINISH — cancelled, or given up on."
        case .problem: "The printer pauses, or reports an error. A filament runout arrives as a "
            + "pause, so it is covered here; the printer has no separate runout state to watch."
        case .plateCool: "The bed cooled through 35 °C after a print — or stopped falling, which on "
            + "a warm day is as cool as it is ever going to get."
        case .dryingDone: "An AMS drying cycle counts down to zero on its own. Stopping one by hand "
            + "stays silent."
        }
    }
}

/// Which alerts are switched on.
struct MacNotifyPrefs: Sendable, Equatable {
    var enabled: Set<MacNotifyKind>

    func isEnabled(_ kind: MacNotifyKind) -> Bool { enabled.contains(kind) }

    /// Reads the toggles out of `UserDefaults`.
    ///
    /// **`UserDefaults.bool(forKey:)` cannot be used here.** It answers `false` for a key that was
    /// never written, which is a different question from "the user switched this off" — and reading
    /// one as the other would leave a fresh install silent until someone opened Settings and
    /// flipped all five switches twice. `object(forKey:)` distinguishes unset from off, which is
    /// the question actually being asked, and it is the same distinction `@AppStorage`'s default
    /// value makes on the pane's side.
    static func load(_ defaults: UserDefaults = .standard) -> MacNotifyPrefs {
        MacNotifyPrefs(enabled: Set(MacNotifyKind.allCases.filter {
            defaults.object(forKey: $0.defaultsKey) as? Bool ?? true
        }))
    }
}

// MARK: - One notification, before it is a UNNotification

struct MacNotifyEvent: Sendable, Equatable, Identifiable {
    /// Stable per (printer, edge). Not used as the `UNNotificationRequest` identifier — see
    /// `MacNotificationController.post` — but it is what a log line names, and what a test asserts.
    var id: String
    /// Which machine this is about. Carried as a field rather than parsed back out of `id`: the
    /// grouping in Notification Centre keys on it, and a split-on-colon would be one renamed id
    /// away from silently grouping every printer together.
    var printerId: Int
    var kind: MacNotifyKind
    var title: String
    var message: String
    /// Plays the default sound. False for anything the user would not want to be woken by.
    var urgent: Bool
}

// MARK: - What the rules read

/// Everything the rules need from one poll of one printer, and nothing else.
///
/// A flat value rather than `(DashVM, PrinterStatus)` so the rules can be exercised without
/// assembling a wire payload — and so the one place that knows the wire shape is `init(printerId:…)`
/// below, small enough to check by eye.
struct MacNotifySample: Sendable, Equatable {
    struct Dryer: Sendable, Equatable {
        var unitId: Int
        /// Minutes remaining. `0` is idle — see `AmsUnitRaw.dryTime`, where `dryStatus` was measured
        /// staying 0 mid-cycle and is therefore not the active signal.
        var minutesLeft: Int
        var filament: String
    }

    var printerId: Int
    var printerName: String
    var kind: DashKind
    /// PAUSE does not change `kind` — `Dash.present` maps it to `.live` — so it is carried
    /// separately and gets its own edge below.
    var isPaused: Bool
    var jobName: String
    var bedC: Double
    /// The printer's own error number as text, when it is reporting one.
    var printErrorText: String?
    /// EVERY AMS unit, including idle ones: a drying cycle finishing is `minutesLeft` falling to
    /// zero, so a unit only present while it is drying would never produce the falling edge.
    var dryers: [Dryer]

    init(
        printerId: Int,
        printerName: String,
        kind: DashKind,
        isPaused: Bool = false,
        jobName: String = "",
        bedC: Double = 0,
        printErrorText: String? = nil,
        dryers: [Dryer] = []
    ) {
        self.printerId = printerId
        self.printerName = printerName
        self.kind = kind
        self.isPaused = isPaused
        self.jobName = jobName
        self.bedC = bedC
        self.printErrorText = printErrorText
        self.dryers = dryers
    }

    /// Pure adapter: what the app already knows → what the rules need.
    init(printerId: Int, printerName: String, vm: DashVM, status: PrinterStatus?) {
        self.init(
            printerId: printerId,
            printerName: printerName,
            kind: vm.kind,
            isPaused: vm.isPaused,
            jobName: (status?.subtaskName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            // The raw reading where there is one. `vm.bedNow` is already rounded to a whole degree,
            // which is enough for the threshold but coarse for the plateau test.
            bedC: status?.temperatures?.bed?.double ?? Double(vm.bedNow),
            printErrorText: Self.printErrorText(status?.printError),
            dryers: (status?.ams ?? []).map {
                Dryer(
                    unitId: $0.id,
                    minutesLeft: SafeInt.rounded($0.dryTime?.double),
                    filament: $0.dryFilament ?? ""
                )
            }
        )
    }

    /// The error number as the printer, Bambu's tables and the user all write it.
    ///
    /// DUPLICATED from `Alerts.present` (Alerts.swift, the `printError`/`printErrorText` pair),
    /// deliberately and reluctantly: the logic there is inline inside a 100-line function and
    /// extracting it touches a file this change does not own. It should become one helper — the two
    /// copies answering "is this a real error code, and how is it written" must not be allowed to
    /// drift.
    static func printErrorText(_ raw: LooseNumber?) -> String? {
        // Zero means "no error", and a transport-mangled non-finite value means nothing at all.
        guard let v = raw?.double, v.isFinite, v != 0 else { return nil }
        if let i = Int(exactly: v) { return String(i) }
        return String(v)
    }
}

// MARK: - Per-printer edge state

/// What one printer's watcher remembers between polls.
///
/// `lastKind == nil` is what makes the FIRST observation silent, and it is load-bearing: attaching
/// to a printer that finished an hour ago, or reconnecting after a Save in Settings, must not
/// announce a print that ended while nobody was watching.
struct MacWatchState: Sendable, Equatable {
    var lastKind: DashKind?
    var wasPaused: Bool?
    var pausedAt: Date?
    var pauseRemindersSent: Int = 0
    /// The last job name seen while there WAS a job. A print that stops goes idle and takes
    /// `subtaskName` with it, so without this the one alert that most needs to name the job —
    /// "stopped before finishing" — is the one that cannot.
    var lastJobName: String = ""
    var cool = MacCoolState()
    /// unit id → what that dryer last reported.
    var dry: [Int: MacDryState] = [:]
}

/// The plate-cooldown gate's state. Mirrors Trellis's `cooldown.py` field for field, because the
/// two must not disagree about whether a plate has been announced.
struct MacCoolState: Sendable, Equatable {
    /// The bed was genuinely hot during a print. Nothing may fire before this.
    var armed = false
    /// Already announced for this print. Cleared when the next print arms it again.
    var fired = false
    /// Trailing bed readings, for the plateau test.
    var seen: [BedSample] = []
}

struct MacDryState: Sendable, Equatable {
    var minutesLeft: Int
    /// Captured while the cycle RUNS. The unit commonly clears `dry_filament` the moment a cycle
    /// ends, so reading it at the edge yields an empty string.
    var filament: String
}

/// What the cooldown gate decided this poll.
enum MacCoolAction: String, Sendable, Equatable {
    /// The bed crossed the threshold.
    case ready
    /// The bed stopped falling short of it — on a warm day that IS as cool as it gets.
    case stalled
}

// MARK: - The rules

/// Pure edge detection: (sample, previous state) → (events, next state).
///
/// Every rule here mirrors one Trellis already applies for the iPhone (`deploy/trellis/app.py`,
/// the `_queue_alert` calls). Same edges, same wording, so the Mac and the phone do not disagree
/// about what happened — they only differ in who noticed.
enum MacNotifyRules {
    /// A paused printer is re-announced at these offsets, then goes quiet rather than nagging.
    /// One banner is a single point of failure for a print that is halted and waiting on a human.
    static let pauseRemindersMin: [Double] = [10, 30, 60]

    /// A bed reading below this is "no data", not a frozen plate — `temperatures` is nullable and a
    /// missing field rounds to 0 upstream.
    static let minValidBedC = 1.0

    /// A drying cycle that had this little left and reached zero ran out naturally. Falling to zero
    /// from more than this is someone stopping it by hand, and they do not need telling.
    static let dryRunoutMaxMin = 15

    static func step(
        _ sample: MacNotifySample,
        state: MacWatchState,
        thresholdC: Double = Cooling.defaultThresholdC,
        now: Date = Date()
    ) -> (events: [MacNotifyEvent], state: MacWatchState) {
        var next = state
        var out: [MacNotifyEvent] = []

        // `offline` and `connecting` are the ABSENCE of a state, not a state. Reading a WebSocket
        // blip as "the print stopped" would announce a failure that never happened — the same
        // reason `LiveActivityController.sync` refuses to end a card on them.
        guard sample.kind != .offline, sample.kind != .connecting else { return (out, next) }

        if !sample.jobName.isEmpty { next.lastJobName = sample.jobName }
        let job = sample.jobName.isEmpty
            ? (state.lastJobName.isEmpty ? "your print" : state.lastJobName)
            : sample.jobName
        let who = sample.printerName.isEmpty ? "Printer" : sample.printerName

        // 1. Kind edges. Edge-triggered, and silent on the first observation.
        if let prev = state.lastKind, prev != sample.kind {
            switch sample.kind {
            case .complete:
                out.append(MacNotifyEvent(
                    id: "\(sample.printerId):complete", printerId: sample.printerId, kind: .finished,
                    title: "✅ \(who) — print finished", message: job, urgent: true
                ))
            case .error:
                let why = sample.printErrorText.map { " The printer reported error \($0)." } ?? ""
                out.append(MacNotifyEvent(
                    id: "\(sample.printerId):error", printerId: sample.printerId, kind: .problem,
                    title: "⚠️ \(who) — needs attention", message: "\(job).\(why)", urgent: true
                ))
            case .idle where prev == .live:
                // A live print that goes IDLE ended WITHOUT completing. This is the case you most
                // want to hear about while you are away, and it is the one a complete/error-only
                // rule cannot see at all.
                out.append(MacNotifyEvent(
                    id: "\(sample.printerId):stopped", printerId: sample.printerId, kind: .stopped,
                    title: "⏹️ \(who) — print stopped",
                    message: "\(job) ended before finishing.", urgent: true
                ))
            default:
                break
            }
        }
        next.lastKind = sample.kind

        // 2. The pause edge, which is NOT a kind edge — `Dash.present` maps PAUSE to `.live`. This
        //    is the alert that matters most: an AI-detection halt and a filament runout both stop
        //    the print and wait for a human, and neither changes `kind`.
        if state.wasPaused != sample.isPaused {
            if state.wasPaused != nil, sample.isPaused {
                let why = sample.printErrorText
                    .map { "Halted with error \($0) — open Sprout to resume or stop it." }
                    ?? "Resume or stop it in Sprout once the problem is fixed."
                out.append(MacNotifyEvent(
                    id: "\(sample.printerId):paused", printerId: sample.printerId, kind: .problem,
                    title: "⏸️ \(who) — print paused", message: "\(job). \(why)", urgent: true
                ))
            }
            next.wasPaused = sample.isPaused
            next.pausedAt = sample.isPaused ? now : nil
            next.pauseRemindersSent = 0
        } else if sample.isPaused, let since = state.pausedAt {
            let mins = now.timeIntervalSince(since) / 60
            let sent = state.pauseRemindersSent
            if sent < pauseRemindersMin.count, mins >= pauseRemindersMin[sent] {
                out.append(MacNotifyEvent(
                    id: "\(sample.printerId):paused:\(Int(pauseRemindersMin[sent]))", printerId: sample.printerId,
                    kind: .problem,
                    title: "⏸️ \(who) — still paused (\(Int(mins)) min)",
                    message: "\(job) is waiting on you.", urgent: true
                ))
                next.pauseRemindersSent = sent + 1
            }
        }

        // 3. The plate is cool enough to lift the print off.
        let (action, coolNext) = coolStep(
            printing: sample.kind == .live,
            bedC: sample.bedC,
            thresholdC: Cooling.clampThreshold(thresholdC),
            state: state.cool,
            now: now
        )
        next.cool = coolNext
        if let action {
            let bed = SafeInt.rounded(sample.bedC)
            // Deliberately "safe to flex", never "your print has released" — plenty of prints stay
            // stuck at room temperature, and promising a pop invites someone to force it and tear
            // the PEI coating off the steel.
            let event = action == .ready
                ? MacNotifyEvent(
                    id: "\(sample.printerId):cool", printerId: sample.printerId, kind: .plateCool,
                    title: "🧊 \(who) — plate is cool",
                    message: "Bed at \(bed) °C. Safe to flex the plate and lift \(job) off.",
                    urgent: false
                )
                : MacNotifyEvent(
                    id: "\(sample.printerId):cool", printerId: sample.printerId, kind: .plateCool,
                    title: "🧊 \(who) — plate has stopped cooling",
                    message: "Settled at \(bed) °C, as cool as it will get today. Go ahead and flex "
                        + "the plate.",
                    urgent: false
                )
            out.append(event)
        }

        // 4. Drying finished, per unit. Three drying-capable units are fitted, so concurrent cycles
        //    are ordinary rather than theoretical — hence a state entry per unit id, not per
        //    printer.
        for dryer in sample.dryers {
            let prev = state.dry[dryer.unitId]
            if let prev, prev.minutesLeft > 0, dryer.minutesLeft <= 0,
               prev.minutesLeft <= dryRunoutMaxMin {
                let filament = prev.filament.isEmpty ? "Filament" : prev.filament
                out.append(MacNotifyEvent(
                    id: "\(sample.printerId):dry:\(dryer.unitId)", printerId: sample.printerId,
                    kind: .dryingDone,
                    title: "💨 \(who) — drying finished", message: "\(filament) is dry.",
                    urgent: false
                ))
            }
            next.dry[dryer.unitId] = MacDryState(
                minutesLeft: dryer.minutesLeft,
                filament: dryer.filament.isEmpty ? (prev?.filament ?? "") : dryer.filament
            )
        }

        return (out, next)
    }

    /// Advance the plate-cooldown gate one poll. Never mutates the state it is given.
    ///
    /// This answers **"has the plate JUST become cool, after a print?"** — an edge, true once.
    /// `Cooling.present` answers **"how cool is the plate right now?"** — a readout, true whenever
    /// it is true. They sound like the same question and are not: the readout is `.ready` for an
    /// idle machine that has been cold for a week, and an announcement driven off it would fire on
    /// every launch forever. The ARM step is the whole difference, and it is why this exists rather
    /// than reading `CooldownStore.vm.phase`.
    ///
    /// The measurements underneath are `Cooling`'s, not a second copy: `clampThreshold` for the
    /// defensible band and `hasPlateaued` for "it stopped falling". Trellis's `cooldown.py` uses a
    /// 15-minute plateau window where `Cooling` uses 10 — the app's own number wins here, so the
    /// alert and the cooldown card on screen never disagree.
    static func coolStep(
        printing: Bool,
        bedC: Double,
        thresholdC: Double,
        state: MacCoolState,
        now: Date
    ) -> (MacCoolAction?, MacCoolState) {
        if printing {
            // Arm only once the bed is genuinely hot, so a cold-bed print — or a printer merely
            // idling warm — cannot set up a spurious announcement. The sample history is dropped
            // with it: the previous cooldown says nothing about this one.
            return (nil, MacCoolState(armed: state.armed || bedC > thresholdC, fired: false, seen: []))
        }
        guard state.armed, !state.fired, bedC.isFinite, bedC >= minValidBedC else {
            return (nil, state)
        }

        var seen = state.seen.filter { now.timeIntervalSince($0.t) <= Cooling.plateauWindowMin * 60 }
        seen.append(BedSample(t: now, c: bedC))

        if bedC <= thresholdC {
            return (.ready, MacCoolState(armed: false, fired: true, seen: []))
        }
        // A plate approaches room temperature asymptotically and cannot cross it, so on a warm day
        // the threshold may simply never arrive. Without this branch the user would be told
        // nothing at all, with nothing to diagnose.
        if Cooling.hasPlateaued(seen, now: now) {
            return (.stalled, MacCoolState(armed: false, fired: true, seen: []))
        }

        var nextState = state
        nextState.seen = seen
        return (nil, nextState)
    }
}

// MARK: - Permission, in words

/// What the Notifications pane says about permission, and what it can offer to do about it.
///
/// Pure, because the wording IS the feature: a pane that shows nothing when permission was refused
/// leaves someone believing alerts are on. Testable for the same reason.
enum MacNotifyAuthorization {
    struct Advice: Sendable, Equatable {
        var label: String
        var detail: String
        /// The app can raise the system prompt itself. Only ever true from `.notDetermined` —
        /// macOS shows the prompt once and silently ignores every later request.
        var canAsk: Bool
        /// The only remaining route is System Settings.
        var canOpenSettings: Bool
        /// Alerts posted right now would actually be seen.
        var willBeSeen: Bool
    }

    static func advice(_ status: UNAuthorizationStatus) -> Advice {
        switch status {
        case .notDetermined:
            return Advice(
                label: "Not asked yet",
                detail: "Sprout has not asked macOS for permission to show notifications. Until it "
                    + "does, none of the alerts below can appear.",
                canAsk: true, canOpenSettings: false, willBeSeen: false
            )
        case .denied:
            return Advice(
                label: "Turned off",
                detail: "Notifications for Sprout are off in System Settings. macOS only shows its "
                    + "own prompt once, so this can only be changed there — the switches below "
                    + "will have no effect until it is.",
                canAsk: false, canOpenSettings: true, willBeSeen: false
            )
        case .authorized:
            return Advice(
                label: "Allowed",
                detail: "macOS will show these as banners and keep them in Notification Centre.",
                canAsk: false, canOpenSettings: true, willBeSeen: true
            )
        case .provisional:
            return Advice(
                label: "Allowed quietly",
                detail: "These are delivered straight to Notification Centre without a banner or a "
                    + "sound. Turn on notifications for Sprout in System Settings to be "
                    + "interrupted by them.",
                canAsk: false, canOpenSettings: true, willBeSeen: true
            )
        @unknown default:
            // Never guessed at. An unknown status is reported as unknown rather than assumed to be
            // permissive, because assuming it is permissive is how a silent app looks healthy.
            return Advice(
                label: "Unknown",
                detail: "macOS reported a permission state Sprout does not recognise. Check "
                    + "Notifications for Sprout in System Settings.",
                canAsk: false, canOpenSettings: true, willBeSeen: false
            )
        }
    }
}

// MARK: - The presenter

/// Shows a banner even when Sprout is the app you are looking at.
///
/// Without a delegate returning presentation options, macOS silently drops a notification posted
/// while the app is frontmost. Since "while Sprout is running" is the ONLY time these fire, that
/// would hide exactly the case the feature exists for.
///
/// Its own object rather than a conformance on the controller: the controller is `@MainActor` and
/// `@Observable`, and this protocol is neither.
final class MacNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

// MARK: - The controller

/// The consumer the Mac never had.
///
/// ## Why these are LOCAL and not remote
///
/// `MacAppDelegate` registers for remote notifications and the entitlement is real
/// (`com.apple.developer.aps-environment`), so a device token does arrive. It cannot be used:
///
///  - Every push Trellis sends goes through Canopy — `_apns_send` has no other path, by design,
///    because Canopy is what holds the APNs signing keys.
///  - Canopy will not push to a token it has not BOUND, and binding requires a claim carrying an
///    App Attest proof (`ClaimBuilder` + `AttestClient`).
///  - **macOS has no App Attest.** The Mac provisioning profile grants no `appattest` entitlement
///    under any spelling — decoded and checked — so `AttestClient.proof` cannot produce one.
///
/// So registering this Mac's token with Trellis would put a token in `_device_tokens` that every
/// banner then tries and fails to deliver to, and would leave a permanent `needs_claim` entry no
/// device can ever satisfy. That is the exact shape of "offering what the backend will refuse", so
/// the token is NOT registered. It is received, logged and surfaced in the pane as what it is —
/// present, and not deliverable — which is the honest consumer for it until macOS has a way to
/// prove itself to the relay.
///
/// The iPhone still receives every one of these remotely from Trellis. Only the Mac has to watch
/// for itself, and only while Sprout is running.
///
/// ## Where the ticks come from
///
/// `attach(model:)` starts a 4-second loop that reads the `PrinterStatusStore` the app ALREADY
/// holds — the same store the menu bar extra reads, and for the same §5.1 reason: no second
/// connection. The loop is owned by this object rather than by a view, so it keeps running with
/// the main window closed, which is when a desk-side Mac is most likely to be the thing that tells
/// you a print finished.
@MainActor
@Observable
final class MacNotificationController {
    static let shared = MacNotificationController()

    /// Permission, as macOS last reported it. Refreshed on start and whenever the pane appears —
    /// it can be changed in System Settings behind the app's back.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// The APNs device token, once one has arrived. **Diagnostic only** — see the note above on why
    /// it is not registered anywhere.
    private(set) var deviceToken: String?

    /// True once a model is attached and the watch loop is running. The pane reports it, because a
    /// pane full of switches over a watcher that is not running is precisely the lie this file
    /// exists to avoid.
    private(set) var isWatching = false

    /// How many printers the last pass actually saw status for.
    ///
    /// Separate from `isWatching` because they are different questions: the loop can be running
    /// perfectly while the app is signed out, offline, or has never received a frame — and in that
    /// state no alert can fire. A single "watching: yes" over an empty fleet is the reassuring half
    /// of the truth.
    private(set) var watchedPrinters = 0

    @ObservationIgnored private weak var model: AppModel?
    /// Which `PrinterStatusStore` the edge state belongs to. See `tick` — this is the only signal
    /// the controller gets that the session changed, because the `AppModel` itself does not.
    @ObservationIgnored private var watchedSession: ObjectIdentifier?
    @ObservationIgnored private var states: [Int: MacWatchState] = [:]
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// Retained here because `UNUserNotificationCenter.delegate` is `weak` — assigned to a
    /// temporary it would be deallocated immediately and every foreground banner would vanish with
    /// no error anywhere.
    @ObservationIgnored private let presenter = MacNotificationPresenter()
    /// Makes each posted request's identifier unique. Reusing one REPLACES the delivered
    /// notification, so two prints finishing would leave one line in Notification Centre.
    @ObservationIgnored private var posted = 0

    /// Matches `AppModel.startDerivedRefresh`'s cadence and Trellis's 5-second poll. Fast enough
    /// that a pause is announced while you are still in the room, cheap enough that it is free —
    /// it reads memory the socket already fills.
    private static let pollInterval: Duration = .seconds(4)

    private init() {}

    // MARK: Lifecycle

    /// Install the presenter and read the current permission. Called from
    /// `MacAppDelegate.applicationDidFinishLaunching`, which is the only place guaranteed to run
    /// before any window exists.
    ///
    /// Deliberately does NOT ask for permission: a prompt on first launch, before the user has
    /// seen the app or told it about a printer, is the prompt everyone denies — and macOS shows it
    /// exactly once. The Notifications pane asks, in context, with a button.
    func start() {
        UNUserNotificationCenter.current().delegate = presenter
        Task { await refreshAuthorization() }
    }

    /// Start watching a session's printers.
    ///
    /// Idempotent for the same model, so it can be called from more than one place without
    /// restarting the loop and losing the pause-reminder counters.
    ///
    /// Called from `MacRoot`, beside the `MacAppDelegate.setOpenHandler` install and for the same
    /// reason: that is the earliest thing in the app that holds the model. A `.task` there is
    /// enough despite the window being closable, because what it starts outlives the view — which
    /// is the whole reason the loop is owned here rather than by a scene.
    ///
    /// It is deliberately NOT attached from the Settings pane. The toggles there default to ON, so
    /// a watcher that only started once someone opened Settings would be promising alerts to
    /// everyone who never went looking.
    func attach(model: AppModel) {
        if self.model === model, watchTask != nil { return }
        self.model = model

        // A watcher outliving its session must clear here. "A reconnect should not re-announce"
        // and "this is a different server now" are different questions, and keeping the old edge
        // state across a Save would let one Bambuddy's printer ids decide what the next one's
        // printers just did.
        states = [:]
        watchTask?.cancel()
        isWatching = true
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick(now: Date())
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// The APNs device token arrived. Recorded and logged; see the type comment for why it goes no
    /// further than this.
    func deviceTokenArrived(_ token: String) {
        guard deviceToken != token else { return }
        deviceToken = token
        // The prefix, never the whole token — the same rule `PostOutcome.logLine` follows: enough
        // to tell two devices apart in a log, not enough to be a push credential lying around in
        // one. `String(...)` because OSLog's interpolation takes a `String`, not a `Substring`.
        let short = String(token.prefix(8))
        macNotifyLog.info(
            "APNs device token \(short, privacy: .public)… received. NOT registered with Trellis: macOS has no App Attest, so the relay could never bind it and every banner sent to it would fail. Alerts on this Mac are posted locally while Sprout runs."
        )
    }

    // MARK: Permission

    func refreshAuthorization() async {
        authorization = await Self.currentAuthorization()
    }

    /// Raise the system prompt, then re-read the answer.
    ///
    /// The result of the request is deliberately not trusted on its own: macOS answers `false` both
    /// for "the user said no" and for "already asked", and only `getNotificationSettings` tells the
    /// two apart.
    func requestAuthorization() async {
        _ = await Self.askForAuthorization()
        await refreshAuthorization()
    }

    /// Wrapped by hand rather than using the `async` overloads: `UNUserNotificationCenter` is not
    /// `Sendable`, and building the center INSIDE the callback keeps it from crossing an isolation
    /// boundary at all.
    private static func currentAuthorization() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private static func askForAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            // No `.badge`: nothing here counts, and a Dock badge that never clears is worse than
            // none. No `.provisional` either — a quiet-by-default alert for a halted printer is
            // the wrong default.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    macNotifyLog.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: The watch loop

    /// One pass over every printer the session can see.
    ///
    /// Every printer, not just the selected one — a card, a banner and a menu bar item are three
    /// different scopes, and this is the one that belongs to the machine rather than to what is on
    /// screen. Watching only the selection is how the OTHER printer's finished print goes
    /// unannounced.
    func tick(now: Date) {
        guard let model else { return }
        // A demo print completing must never post a notification: it would be a true-looking
        // statement about a printer that does not exist.
        guard !model.isDemo else { return }

        // A reconnect — Settings → Save, or leaving demo mode — builds a NEW `PrinterStatusStore`
        // while keeping the SAME `AppModel`, so `attach` never sees it and the edge state would
        // survive into a different server. Printer ids are small integers that collide across
        // Bambuddys, so "printer 1 was live and is now idle" could be assembled from two machines.
        //
        // "A reconnect should not re-announce" and "this is a different server now" are different
        // questions; `attach` answers the first, this answers the second. Signing out clears it
        // too, because `status` becomes nil and nil is a different session from any store.
        let session = model.status.map(ObjectIdentifier.init)
        if session != watchedSession {
            states = [:]
            watchedSession = session
        }

        let statuses = model.status?.statuses ?? [:]
        // Drop watchers for printers this session no longer has, so a fleet change cannot leave
        // stale edge state to be matched against a reused id.
        states = states.filter { statuses.keys.contains($0.key) }
        watchedPrinters = statuses.count
        guard !statuses.isEmpty else { return }

        let prefs = MacNotifyPrefs.load()
        for (id, status) in statuses {
            let sample = MacNotifySample(
                printerId: id,
                printerName: model.printers.first { $0.id == id }?.name ?? "",
                vm: Dash.present(status),
                status: status
            )
            let (events, next) = MacNotifyRules.step(sample, state: states[id] ?? MacWatchState(), now: now)
            states[id] = next
            for event in events where prefs.isEnabled(event.kind) { post(event) }
        }
    }

    /// Hand one event to macOS.
    private func post(_ event: MacNotifyEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.message
        content.sound = event.urgent ? UNNotificationSound.default : nil
        // `.active`, never `.timeSensitive`. Time-sensitive needs
        // `com.apple.developer.usernotifications.time-sensitive`, which the iOS entitlements file
        // carries and the macOS one does not — and an entitlement the profile lacks is not
        // refused, it is silently filtered out. Asking for a level this build cannot have would
        // read as a guarantee.
        content.interruptionLevel = .active
        // Groups a printer's alerts together in Notification Centre rather than interleaving two
        // machines.
        content.threadIdentifier = "sprout.printer.\(event.printerId)"

        posted += 1
        let request = UNNotificationRequest(
            identifier: "\(event.id)#\(posted)",
            content: content,
            trigger: nil     // deliver now
        )
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            // Logged rather than swallowed. A refusal here is invisible from every other angle: the
            // edge has already advanced, so nothing will re-fire, and the user simply is not told.
            macNotifyLog.error(
                "could not post \(event.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        macNotifyLog.info("posted \(event.id, privacy: .public)")
    }
}
#endif

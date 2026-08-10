import Foundation
import SwiftUI

/// `Double` → `Int` without trapping.
///
/// `Int(_:)` is a runtime TRAP — not a zero — for NaN, ±infinity, and for any finite magnitude past
/// ~9.22e18, and these values arrive off the wire: Bambuddy's WebSocket serializer stringifies
/// numerics and `LooseNumber` parses `"nan"`, `"inf"` and `"1e30"` without complaint. Saturating
/// keeps the RN behaviour (which rendered the silly number) instead of killing the dashboard.
///
/// Shared because the sibling Domain modules each grew their own copy of this guard, and the two
/// modules on the primary render path were the ones that skipped it.
enum SafeInt {
    /// Nearest whole value, ties away from zero — for display numbers.
    static func rounded(_ v: Double?) -> Int { clamped(v?.rounded()) }

    /// Truncated toward zero — for divisions like minutes → hours, where rounding up would report
    /// "2h 00m" for 119 minutes.
    static func truncated(_ v: Double?) -> Int { clamped(v?.rounded(.towardZero)) }

    private static func clamped(_ v: Double?) -> Int {
        guard let v, v.isFinite else { return 0 }
        if v >= Double(Int.max) { return .max }
        if v <= Double(Int.min) { return .min }
        return Int(v)
    }
}

enum DashKind: String, Sendable, Hashable {
    case connecting, offline, idle, live, complete, error
}

/// A semantic state colour, resolved against the active `Palette` at render time.
///
/// The RN version stored a literal colour string and had to rebuild the whole VM on every theme
/// switch (its comment: "capturing their values at module scope would freeze the dark palette
/// forever"). Naming the token instead makes the VM genuinely theme-independent and lets it be a
/// plain `Sendable` value.
enum StateColor: String, Sendable, Hashable {
    case idle, error, paused, running, heating

    func resolve(_ p: Palette) -> Color {
        switch self {
        case .idle: return p.idle
        case .error: return p.error
        case .paused: return p.paused
        case .running: return p.running
        case .heating: return p.heating
        }
    }
}

struct NozzleVM: Hashable, Sendable, Identifiable {
    var now: Int
    var target: Int
    var heating: Bool
    /// The extruder currently doing the work (always true on single-nozzle machines).
    var active: Bool
    var index: Int
    var id: Int { index }
}

struct DashVM: Hashable, Sendable {
    var kind: DashKind = .connecting
    var stateLabel: String = "Connecting"
    var stateColor: StateColor = .idle
    var heroSub: String = ""
    var progressInt: Int = 0
    var layer: String = "0"
    var totalLayers: String = "0"
    var etaText: String = "—"
    var doneText: String = "—"
    /// The ACTIVE nozzle (of 1 or 2) — what the compact views and Live Activity show.
    var nozzleNow: Int = 0
    var nozzleTarget: Int = 0
    var nozzleHeating: Bool = false
    /// All nozzles, in payload order — dual-nozzle machines (H2-series) have 2.
    var nozzles: [NozzleVM] = []
    var bedNow: Int = 0
    var bedTarget: Int = 0
    var bedHeating: Bool = false
    /// Chamber temperature — only on enclosed machines.
    var hasChamber: Bool = false
    var chamberNow: Int = 0
    var chamberTarget: Int = 0
    var chamberHeating: Bool = false
    var isPaused: Bool = false
    var lightOn: Bool = false
    var speedIdx: Int = 2        // 1..4, from the printer's real speedLevel
    var speedLabel: String = "Standard"
    /// Non-blocking HMS notices (the printer keeps printing) — shown as a warning chip, not an error
    /// screen.
    var hmsCount: Int = 0
    var hmsCode: String?
    /// FINISH + plate not confirmed clear — the queue is blocked until the user confirms.
    var awaitingPlateClear: Bool = false
    /// The archive to re-queue, or nil when there is nothing to re-print.
    ///
    /// "The print finished" is a NEARBY question, not this one: a job Bambuddy never archived — one
    /// started from the printer's own screen or off its SD card, or a FINISH that landed before the
    /// archive row was written — reports no id, and `POST /queue/` has nothing to send. A "Print
    /// again" button gated on `kind == .complete` therefore did nothing at all when tapped.
    var reprintArchiveId: Int?
    /// Every slot across every AMS unit, flat and in unit order.
    var ams: [AmsSlotVM] = []
    /// The units those slots belong to — grouping, capacity, drying ceiling, fed extruder.
    var amsUnits: [AmsUnitVM] = []
    /// `.switch` when a Filament Track Switch routes units dynamically.
    var amsRouting: AmsRouting = .fixed
}

enum Dash {
    static let speedLabels = ["", "Silent", "Standard", "Sport", "Ludicrous"]

    static func fmtDuration(_ minutes: Double) -> String {
        guard minutes.isFinite, minutes > 0 else { return "—" }
        // `isFinite` bounds the remainder but not the quotient: 1e30 minutes is finite and its hour
        // count is not representable, which `Int(_:)` answers with a trap.
        let h = SafeInt.truncated(minutes / 60)
        let m = Int(minutes.truncatingRemainder(dividingBy: 60).rounded())
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    static func fmtClock(_ date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        var h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let ap = h >= 12 ? "PM" : "AM"
        h = h % 12 == 0 ? 12 : h % 12
        return "\(h):\(String(format: "%02d", m)) \(ap)"
    }

    /// "0500050000010007" -> "0500-0500-0001-0007" (the format Bambu's HMS docs use).
    static func fmtHmsCode(_ fullCode: String?) -> String? {
        guard let s = fullCode, !s.isEmpty else { return nil }
        guard s.count == 16 else { return s }
        return stride(from: 0, to: 16, by: 4)
            .map { String(Array(s)[$0..<($0 + 4)]) }
            .joined(separator: "-")
    }

    private static func round(_ n: Double?) -> Int { SafeInt.rounded(n) }

    /// Heating: trust the payload's explicit flag when present, else derive from the temp gap.
    private static func heating(_ explicit: Bool?, now: Int, target: Int, gap: Int) -> Bool {
        if let explicit { return explicit }
        return target > 0 && now < target - gap
    }

    /// Pure: map a `PrinterStatus` into the Dashboard's display values.
    static func present(_ status: PrinterStatus?, now: Date = Date()) -> DashVM {
        guard let status else { return DashVM() }
        guard status.connected else {
            return DashVM(kind: .offline, stateLabel: "Offline", stateColor: .idle, heroSub: "No response from the printer")
        }

        let state = status.state.uppercased()
        let t = status.temperatures ?? Temperatures()

        // Nozzles: single machines report `nozzle`; dual (H2-series) add `nozzle2`.
        var nozzles: [NozzleVM] = [
            NozzleVM(
                now: round(t.nozzle?.double),
                target: round(t.nozzleTarget?.double),
                heating: heating(t.nozzleHeating, now: round(t.nozzle?.double), target: round(t.nozzleTarget?.double), gap: 3),
                active: true,
                index: 0
            )
        ]
        if t.nozzle2 != nil {
            nozzles.append(NozzleVM(
                now: round(t.nozzle2?.double),
                target: round(t.nozzle2Target?.double),
                heating: heating(t.nozzle2Heating, now: round(t.nozzle2?.double), target: round(t.nozzle2Target?.double), gap: 3),
                active: false,
                index: 1
            ))
        }

        // Which head is doing the work. TWO different numbering schemes meet here and MUST NOT be
        // compared index-to-index (that mismatch caused every past "wrong nozzle" bug):
        //  - temperature keys are POSITION-ordered: `nozzle` = LEFT head, `nozzle2` = RIGHT;
        //  - `activeExtruder` uses Bambu's extruder ids: 0 = RIGHT, 1 = LEFT.
        // Verified live on the H2C (2026-07-18, print running on the right 0.6): activeExtruder=0
        // with nozzle2 driven at 220/220 and nozzle idle at 44. Order of trust: the DRIVEN head
        // (exactly one target set — self-evident), then the mapped activeExtruder (breaks the tie
        // when both/neither are driven, e.g. mid tool-change), then the hotter head.
        var activeIdx = 0
        if nozzles.count > 1 {
            let driven0 = nozzles[0].target > 0
            let driven1 = nozzles[1].target > 0
            let ae = status.activeExtruder?.int
            if driven0 != driven1 {
                activeIdx = driven1 ? 1 : 0
            } else if ae == 0 || ae == 1 {
                activeIdx = ae == 0 ? 1 : 0   // 0 = right -> nozzle2 (idx 1)
            } else {
                activeIdx = nozzles[1].now > nozzles[0].now ? 1 : 0
            }
        }
        for i in nozzles.indices { nozzles[i].active = (i == activeIdx) }
        let active = nozzles[safe: activeIdx] ?? nozzles[0]

        let bedNow = round(t.bed?.double)
        let bedTarget = round(t.bedTarget?.double)
        let bedHeating = heating(t.bedHeating, now: bedNow, target: bedTarget, gap: 2)

        let hasChamber = t.chamber != nil
        let chamberNow = round(t.chamber?.double)
        let chamberTarget = round(t.chamberTarget?.double)
        let chamberHeating = hasChamber && heating(t.chamberHeating, now: chamberNow, target: chamberTarget, gap: 2)

        // ALL units, not just ams[0] — the H2C runs two AMS 2 Pro alongside an AMS HT. `present` also
        // owns the tray-id math: `active` compares trayNow to the GLOBAL id.
        let ams = AmsTopology.present(status)

        let speedRaw = status.speedLevel?.int ?? 0
        let speedIdx = (1...4).contains(speedRaw) ? speedRaw : 2
        let hmsCount = status.hmsErrors?.count ?? 0
        let hmsCode = fmtHmsCode(status.hmsErrors?.first?.fullCode ?? status.hmsErrors?.first?.code)

        let remaining = status.remainingTime?.double ?? 0
        var vm = DashVM()
        vm.heroSub = status.subtaskName ?? ""
        vm.progressInt = round(status.progress?.double)
        vm.layer = String(status.layerNum?.int ?? 0)
        vm.totalLayers = String(status.totalLayers?.int ?? 0)
        vm.etaText = fmtDuration(remaining)
        vm.doneText = remaining > 0 ? fmtClock(now.addingTimeInterval(remaining * 60)) : "—"
        vm.nozzleNow = active.now
        vm.nozzleTarget = active.target
        vm.nozzleHeating = active.heating
        vm.nozzles = nozzles
        vm.bedNow = bedNow
        vm.bedTarget = bedTarget
        vm.bedHeating = bedHeating
        vm.hasChamber = hasChamber
        vm.chamberNow = chamberNow
        vm.chamberTarget = chamberTarget
        vm.chamberHeating = chamberHeating
        vm.lightOn = status.chamberLight == true
        vm.speedIdx = speedIdx
        vm.speedLabel = speedLabels[speedIdx]
        vm.hmsCount = hmsCount
        vm.hmsCode = hmsCode
        vm.awaitingPlateClear = status.awaitingPlateClear == true
        vm.reprintArchiveId = status.currentArchiveId
        vm.ams = ams.slots
        vm.amsUnits = ams.units
        vm.amsRouting = ams.routing

        // A real failure: the backend's printError, or an explicit failed state. An hmsErrors entry
        // alone is NOT an error — the H2C emits benign notices mid-print; they surface via hmsCount.
        if (status.printError?.double ?? 0) != 0 || state == "FAILED" || state == "ERROR" {
            vm.kind = .error; vm.stateLabel = "Error"; vm.stateColor = .error
            return vm
        }
        if state == "PAUSE" || state == "PAUSED" {
            vm.kind = .live; vm.isPaused = true; vm.stateLabel = "Paused"; vm.stateColor = .paused
            return vm
        }
        if state == "FINISH" || state == "FINISHED" || state == "FINISHING" {
            vm.kind = .complete; vm.stateLabel = "Complete"; vm.stateColor = .running
            return vm
        }
        if state == "IDLE" || state.isEmpty || state == "UNKNOWN" {
            vm.kind = .idle; vm.stateLabel = "Idle"; vm.stateColor = .idle; vm.heroSub = "No active job"
            return vm
        }
        // Live. Prefer the printer's own sub-stage name ("Changing filament", "Auto bed leveling"…);
        // fall back to the heating heuristic.
        let stage = (status.stgCurName ?? "").trimmingCharacters(in: .whitespaces)
        let inStage = !stage.isEmpty && stage.lowercased() != "printing"
        let heatingUp = (active.heating || bedHeating) && (status.progress?.double ?? 0) < 2
        vm.kind = .live
        vm.stateLabel = inStage ? stage : (heatingUp ? "Heating" : "Printing")
        vm.stateColor = (inStage || heatingUp) ? .heating : .running
        return vm
    }
}

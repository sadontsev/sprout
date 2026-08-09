import ActivityKit
import Foundation
import Observation

/// Builds Live Activity content from live status, and owns the app's side of the card lifecycle.
///
/// Two ownership modes, and exactly one owner at a time:
/// - **SERVER** (a la-push URL resolves): the server starts, updates and ends every card. The app
///   never calls `request` — it registers push tokens and reconciles, reporting the full set of live
///   activities so the server can notice a user-swiped dismissal.
/// - **LOCAL** (no push URL): the app owns cards outright.
///
/// Getting this wrong is what produced the duplicate-card bug: two owners both starting a card for
/// the same print.
@MainActor
@Observable
final class LiveActivityController {
    private let pushUrl: String?
    private let apiKey: String
    /// Last content pushed per activity key, for change gating.
    private var lastContent: [String: PrintActivityAttributes.ContentState] = [:]
    private var lastUpdate: [String: Date] = [:]

    /// Minimum gap between updates for one card. ActivityKit throttles aggressively and a card that
    /// updates every status frame gets its budget cut.
    private static let throttle: TimeInterval = 4

    var isServerOwned: Bool { pushUrl != nil }

    init(config: AppConfig) {
        pushUrl = ConfigRules.resolvePushUrl(config)
        apiKey = config.apiKey
    }

    // MARK: - Content mapping
    //
    // These are pure functions over value types, so they are `nonisolated`: they carry no instance
    // state, and forcing callers onto the main actor to compute a struct would be noise.

    /// Theme-independent tint for a print card, derived from the semantic state rather than a themed
    /// colour, so the same print looks identical whoever built the card.
    nonisolated static func tint(_ vm: DashVM) -> String {
        if vm.kind == .error { return LAColors.error }
        if vm.isPaused { return LAColors.paused }
        if vm.kind == .idle || vm.kind == .offline || vm.kind == .connecting { return LAColors.idle }
        if vm.kind == .complete { return LAColors.running }
        return vm.stateColor == .heating ? LAColors.heating : LAColors.running
    }

    nonisolated private static let symbols: [String: String] = [
        "Printing": "printer.fill",
        "Heating": "thermometer.medium",
        "Paused": "pause.circle.fill",
        "Complete": "checkmark.circle.fill",
        "Error": "exclamationmark.triangle.fill",
    ]

    /// Pure: view-model + raw status → the flat content state the card renders.
    nonisolated static func content(
        vm: DashVM,
        status: PrinterStatus,
        now: Date = Date(),
        printerName: String = "",
        iconUri: String = "",
        modelUri: String = "",
        queueCount: Int = 0,
        nextName: String = ""
    ) -> PrintActivityAttributes.ContentState {
        let finished = vm.kind == .complete
        let remainingMin = status.remainingTime?.double ?? 0
        let t = status.temperatures
        let dual = vm.nozzles.count > 1
        let activeNozzle = max(0, vm.nozzles.firstIndex { $0.active } ?? 0)

        var s = PrintActivityAttributes.ContentState()
        s.printerName = printerName
        s.iconUri = iconUri
        s.modelUri = modelUri
        s.queueCount = queueCount
        s.nextName = nextName
        s.name = status.subtaskName ?? ""
        s.stateLabel = vm.stateLabel
        s.progress = vm.progressInt
        s.layer = status.layerNum?.int ?? 0
        s.totalLayers = status.totalLayers?.int ?? 0
        s.etaEpochMs = (!finished && remainingMin > 0) ? now.addingTimeInterval(remainingMin * 60).timeIntervalSince1970 * 1000 : 0
        s.finished = finished
        s.symbol = symbols[vm.stateLabel] ?? (vm.kind == .error ? "exclamationmark.triangle.fill" : "printer.fill")
        s.tint = tint(vm)
        s.nozzle = Int((t?.nozzle?.double ?? 0).rounded())
        s.nozzleTarget = Int((t?.nozzleTarget?.double ?? 0).rounded())
        s.nozzle2 = Int((t?.nozzle2?.double ?? 0).rounded())
        s.nozzle2Target = Int((t?.nozzle2Target?.double ?? 0).rounded())
        s.hasNozzle2 = dual
        s.activeNozzle = activeNozzle
        s.bed = Int((t?.bed?.double ?? 0).rounded())
        s.bedTarget = Int((t?.bedTarget?.double ?? 0).rounded())
        return s
    }

    /// Ids of the units with an ACTIVE drying cycle, in payload order.
    ///
    /// `dryTime` (minutes remaining) > 0 is THE active signal — `dryStatus` stayed 0 mid-cycle on the
    /// live machine. Three drying-capable units are fitted, so concurrent cycles are ordinary rather
    /// than theoretical.
    nonisolated static func dryingUnitIds(_ status: PrinterStatus?) -> [Int] {
        (status?.ams ?? []).filter { ($0.dryTime?.double ?? 0) > 0 }.map(\.id)
    }

    /// One unit's drying status → a drying-card content state, or nil when that unit is idle.
    ///
    /// Scans EVERY unit, not `ams[0]`: a cycle on the HT produced no card at all. The card names its
    /// unit so it is unambiguous which one is drying.
    nonisolated static func dryContent(_ status: PrinterStatus, amsId: Int, now: Date = Date(), printerName: String = "", iconUri: String = "") -> PrintActivityAttributes.ContentState? {
        let units = status.ams ?? []
        guard let ams = units.first(where: { $0.id == amsId }) else { return nil }
        let mins = ams.dryTime?.double ?? 0
        guard mins > 0 else { return nil }

        let isHt = ams.isAmsHt == true || ams.id >= 128
        let unitLabel = units.count > 1 ? (isHt ? "AMS HT" : "AMS \(ams.id + 1)") : ""
        let target = Int((ams.dryTargetTemp?.double ?? 0).rounded())
        let filament = ams.dryFilament?.isEmpty == false ? ams.dryFilament! : "Filament"

        var s = PrintActivityAttributes.ContentState()
        s.printerName = printerName
        s.iconUri = iconUri
        s.dry = true
        s.stateLabel = "Drying"
        s.name = [unitLabel, target > 0 ? "\(filament) @ \(target)°" : filament]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        s.tint = LAColors.drying
        s.symbol = "humidity.fill"
        s.finished = false
        s.progress = 0
        s.etaEpochMs = now.addingTimeInterval(mins * 60).timeIntervalSince1970 * 1000
        s.amsTemp = Int((ams.temp?.double ?? 0).rounded())
        s.amsTarget = target
        s.humidity = Int((ams.humidity?.double ?? 0).rounded())
        return s
    }

    /// Whether a change is worth spending an update on.
    ///
    /// Temps and ETA are on the card, so without them a heat-up that doesn't advance progress or
    /// layer never updates and the card shows cold temperatures for minutes.
    nonisolated static func meaningfulChange(from a: PrintActivityAttributes.ContentState?, to b: PrintActivityAttributes.ContentState) -> Bool {
        guard let a else { return true }
        return abs(a.progress - b.progress) >= 1
            || a.layer != b.layer
            || a.stateLabel != b.stateLabel
            || a.name != b.name
            || a.printerName != b.printerName
            || a.modelUri != b.modelUri
            || a.queueCount != b.queueCount
            || a.nextName != b.nextName
            || abs(a.nozzle - b.nozzle) >= 2
            || abs(a.nozzle2 - b.nozzle2) >= 2
            || a.nozzleTarget != b.nozzleTarget
            || a.nozzle2Target != b.nozzle2Target
            || a.activeNozzle != b.activeNozzle
            || abs(a.bed - b.bed) >= 2
            || a.bedTarget != b.bedTarget
            || abs(a.etaEpochMs - b.etaEpochMs) >= 60_000
            || (a.dry ?? false) != (b.dry ?? false)
            || abs((a.amsTemp ?? 0) - (b.amsTemp ?? 0)) >= 1
            || (a.amsTarget ?? 0) != (b.amsTarget ?? 0)
            || abs((a.humidity ?? 0) - (b.humidity ?? 0)) >= 2
    }

    // MARK: - Lifecycle

    private func key(printerId: Int, amsId: Int?) -> String {
        amsId.map { "dry:\(printerId):\($0)" } ?? "print:\(printerId)"
    }

    /// Reconcile the app's view of live cards with what should exist.
    ///
    /// `offline` and `connecting` are deliberately no-ops: a WebSocket blip must never kill a card
    /// that represents a print still running.
    func sync(printerId: Int, printerName: String, vm: DashVM, status: PrinterStatus?) async {
        guard let status else { return }
        guard vm.kind != .offline, vm.kind != .connecting else { return }

        let shouldHavePrintCard = vm.kind == .live || vm.kind == .complete || vm.kind == .error
        let printState = Self.content(vm: vm, status: status, printerName: printerName)

        if shouldHavePrintCard {
            await upsert(printerId: printerId, amsId: nil, content: printState, ended: vm.kind == .complete)
        } else {
            await end(printerId: printerId, amsId: nil)
        }

        // One card per drying unit — a per-printer key silently hid the second concurrent cycle.
        let drying = Set(Self.dryingUnitIds(status))
        for unitId in drying {
            if let dry = Self.dryContent(status, amsId: unitId, printerName: printerName) {
                await upsert(printerId: printerId, amsId: unitId, content: dry, ended: false)
            }
        }
        for activity in Activity<PrintActivityAttributes>.activities {
            if let amsId = activity.attributes.amsId,
               activity.attributes.printerId == printerId,
               !drying.contains(amsId) {
                await end(printerId: printerId, amsId: amsId)
            }
        }
    }

    private func upsert(printerId: Int, amsId: Int?, content: PrintActivityAttributes.ContentState, ended: Bool) async {
        let k = key(printerId: printerId, amsId: amsId)

        guard Self.meaningfulChange(from: lastContent[k], to: content) else { return }
        if let last = lastUpdate[k], Date().timeIntervalSince(last) < Self.throttle, !ended { return }

        // Updated inside the loop rather than through a captured optional: an `Activity` bound to a
        // local cannot cross into the nonisolated `update`, but a fresh loop binding can.
        var updated = false
        for activity in Activity<PrintActivityAttributes>.activities
        where activity.attributes.printerId == printerId && activity.attributes.amsId == amsId {
            await activity.update(ActivityContent(state: content, staleDate: nil))
            updated = true
        }
        if updated {
            lastContent[k] = content
            lastUpdate[k] = Date()
            return
        }

        // In server mode the server is the only thing allowed to create a card. Starting one here as
        // well is precisely how a print ended up with two.
        guard !isServerOwned else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        do {
            let activity = try Activity.request(
                attributes: PrintActivityAttributes(printerId: printerId, amsId: amsId),
                content: ActivityContent(state: content, staleDate: nil),
                pushType: pushUrl == nil ? nil : .token
            )
            lastContent[k] = content
            lastUpdate[k] = Date()
            if pushUrl != nil { observePushToken(activity) }
        } catch {
            // A refused start is not worth surfacing — the user may simply have Live Activities off.
        }
    }

    func end(printerId: Int, amsId: Int?) async {
        let k = key(printerId: printerId, amsId: amsId)
        lastContent[k] = nil
        lastUpdate[k] = nil
        for activity in Activity<PrintActivityAttributes>.activities
        where activity.attributes.printerId == printerId && activity.attributes.amsId == amsId {
            await activity.end(nil, dismissalPolicy: .default)
        }
    }

    /// Report each card's push token to la-push, and keep reporting on rotation. The token is the
    /// only identity an adopted card exposes, so it is what the server keys on.
    private func observePushToken(_ activity: Activity<PrintActivityAttributes>) {
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                await self?.register(token: token, activity: activity)
            }
        }
    }

    private func register(token: String, activity: Activity<PrintActivityAttributes>) async {
        guard let pushUrl, let url = URL(string: pushUrl + "/register-activity") else { return }
        struct Body: Encodable {
            let token: String
            let printerId: Int
            let amsId: Int?
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try? encoder.encode(Body(
            token: token,
            printerId: activity.attributes.printerId,
            amsId: activity.attributes.amsId
        ))
        _ = try? await URLSession.shared.data(for: req)
    }
}

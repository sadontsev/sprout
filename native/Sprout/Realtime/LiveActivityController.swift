import ActivityKit
import Foundation
import Observation

/// What this build calls itself when it registers with Trellis.
///
/// The RN app and this one ship as different TestFlight builds of the SAME bundle id and both talk to
/// one Trellis, but their Live-Activity wire shapes are incompatible: expo-widgets' ContentState is
/// `Codable{name, props}` with the fields serialized into `props`, ours is flat, and push-to-start
/// names a different attributes type (`PrintActivityAttributes` + `{printerId, amsId}`, not
/// `LiveActivityAttributes` + `{}`). The server cannot tell from a push token which app sent it, and
/// getting it wrong is invisible from both ends — APNs answers 200 and the card simply never updates
/// or never appears. So every registration says who it came from; omitting the field means "expo",
/// which is what keeps the already-installed RN build working untouched.
private let laPushClient = "native"

/// Builds Live Activity content from live status, and owns the app's side of the card lifecycle.
///
/// Two ownership modes, and exactly one owner at a time:
/// - **SERVER** (a Trellis URL resolves): the server starts every card by push-to-start, pushes every
///   update off its own poll, and ends it. The app's entire job is to hand over two tokens — the
///   device's push-to-start token, and each card's per-activity update token once a card exists — and
///   to notice dismissal. It calls neither `request` nor `update`.
/// - **LOCAL** (no push URL): the app owns cards outright and registers nothing.
///
/// Getting this wrong is what produced the duplicate-card bug: two owners both starting a card for
/// the same print. Getting only *half* of SERVER mode right is worse than either: an app that refuses
/// to start a card and also registers no start token leaves the lock screen empty for the whole
/// print, because the server has nothing to push a start to.
@MainActor
@Observable
final class LiveActivityController {
    private let pushUrl: String?
    private let apiKey: String
    /// Last content pushed per activity key, for change gating.
    private var lastContent: [String: PrintActivityAttributes.ContentState] = [:]
    private var lastUpdate: [String: Date] = [:]

    /// Card keys the user swiped away, so a dismissal sticks for the rest of that print. Dedup used to
    /// be derived purely from `Activity.activities`, which a dismissed card leaves — so the next 2 °C
    /// of nozzle drift started a brand-new card and the user could not get rid of it at all. Cleared
    /// in `end`: once the print (or drying cycle) that card stood for is over, the next one may have
    /// a card again.
    private var dismissed: Set<String> = []
    /// Activity ids this controller ended itself. ActivityKit reports `.dismissed` for those too, once
    /// the system finally clears the card off the screen, and reading that as a user swipe would
    /// suppress the NEXT print's card.
    private var endedByApp: Set<String> = []
    /// Activity ids already wired to their state (and, in SERVER mode, push-token) streams.
    private var observed: Set<String> = []
    /// Latest APNs update token per activity id, kept so a failed registration can be retried without
    /// waiting for the token to rotate — tokens rotate rarely, and a card with no token registered is
    /// a card frozen at the content it was created with.
    private var tokens: [String: String] = [:]
    /// `"<activity id>|<token>"` pairs Trellis has accepted.
    private var registered: Set<String> = []
    private var lastRegisterAttempt: [String: Date] = [:]

    /// Minimum gap between updates for one card. ActivityKit throttles aggressively and a card that
    /// updates every status frame gets its budget cut.
    private static let throttle: TimeInterval = 4
    /// Minimum gap between registration attempts for one (card, token) pair. `sync` runs every 4 s and
    /// an unreachable Trellis must not turn that into a POST storm.
    private static let registerRetry: TimeInterval = 30

    var isServerOwned: Bool { pushUrl != nil }

    init(config: AppConfig) {
        pushUrl = ConfigRules.resolvePushUrl(config)
        apiKey = config.apiKey
        startObserving()
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
    /// The rule for this list: **every field the widget renders belongs in it**, with a threshold only
    /// on the numerically noisy ones. Temps and ETA are on the card, so without them a heat-up that
    /// doesn't advance progress or layer never updates and the card shows cold temperatures for
    /// minutes. `totalLayers` is on it for the same reason with a sharper edge: the widget hides the
    /// whole layer row until `totalLayers > 0`, and Bambuddy commonly reports the total on a frame
    /// where nothing else moves — leaving that field out kept the row hidden until the first layer
    /// finished.
    nonisolated static func meaningfulChange(from a: PrintActivityAttributes.ContentState?, to b: PrintActivityAttributes.ContentState) -> Bool {
        guard let a else { return true }
        return abs(a.progress - b.progress) >= 1
            || a.layer != b.layer
            || a.totalLayers != b.totalLayers
            || a.stateLabel != b.stateLabel
            || a.name != b.name
            || a.printerName != b.printerName
            || a.modelUri != b.modelUri
            || a.iconUri != b.iconUri
            || a.queueCount != b.queueCount
            || a.nextName != b.nextName
            || a.finished != b.finished
            || a.symbol != b.symbol
            || a.tint != b.tint
            || abs(a.nozzle - b.nozzle) >= 2
            || abs(a.nozzle2 - b.nozzle2) >= 2
            || a.nozzleTarget != b.nozzleTarget
            || a.nozzle2Target != b.nozzle2Target
            || a.hasNozzle2 != b.hasNozzle2
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
        // Cards also appear without us: in SERVER mode Trellis starts them remotely, and cards from a
        // previous launch outlive the process. Sweeping here — not only from `activityUpdates`, whose
        // replay of already-live activities is not something to bet a subsystem on — is what
        // guarantees every card ends up wired to its dismissal and push-token streams.
        adoptExistingActivities()

        // Deliberately not awaited: this loop runs every 4 s and also drives the cooldown readout, so
        // a slow Trellis must not stall it. `lastRegisterAttempt` is stamped BEFORE the request, so an
        // overlapping flush cannot double-POST.
        if isServerOwned, !tokens.isEmpty { Task { [weak self] in await self?.flushRegistrations() } }

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
        // SERVER mode: the server is the sole WRITER as well as the sole creator, so this returns
        // before touching a card or the gate state behind it. Two writers do not merely halve the
        // ActivityKit budget — Trellis pushes off a 5 s poll while the app reads a socket, so the two
        // hold different snapshots and the card's progress visibly jitters backwards. The local gate
        // (`lastContent`/`lastUpdate`) also knows nothing about what the server last rendered, so the
        // two sides cannot even agree on what counts as a change.
        guard !isServerOwned else { return }

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

        // No card exists, so this is a creation. Respect a swipe: the user removing a card is an
        // instruction, not a glitch to heal.
        guard !dismissed.contains(k) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        do {
            // `pushType: nil` is not a shortcut: this branch is LOCAL-ONLY (the guard above returns in
            // SERVER mode), and LOCAL means there is no server to hand an APNs token to.
            let activity = try Activity.request(
                attributes: PrintActivityAttributes(printerId: printerId, amsId: amsId),
                content: ActivityContent(state: content, staleDate: nil),
                pushType: nil
            )
            lastContent[k] = content
            lastUpdate[k] = Date()
            observe(activity)
        } catch {
            // A refused start is not worth surfacing — the user may simply have Live Activities off.
        }
    }

    /// Take a card down. Unlike `update`, this runs in BOTH modes on purpose: ending is terminal and
    /// idempotent, so the worst a duplicated end can do is remove a card a few seconds before Trellis
    /// would have. The failure it prevents is far worse — a server that dies mid-print leaves a card
    /// counting down to a stale ETA on the lock screen with nothing able to clear it.
    func end(printerId: Int, amsId: Int?) async {
        let k = key(printerId: printerId, amsId: amsId)
        lastContent[k] = nil
        lastUpdate[k] = nil
        // The card's subject is over, so a swipe of it must not suppress the next print's card.
        dismissed.remove(k)
        for activity in Activity<PrintActivityAttributes>.activities
        where activity.attributes.printerId == printerId && activity.attributes.amsId == amsId {
            endedByApp.insert(activity.id)
            await activity.end(nil, dismissalPolicy: .default)
        }
    }

    // MARK: - Ownership plumbing

    /// Attach everything the app is responsible for regardless of who owns the cards.
    private func startObserving() {
        // The push-to-start token is the ONLY way Trellis can create a card while the app is closed,
        // and `upsert` refuses to create one in SERVER mode — so without this registration neither
        // party ever starts a card and the lock screen simply stays empty for the whole print. The
        // stream emits the current token as soon as it is iterated, then again on rotation.
        if isServerOwned {
            Task { [weak self] in
                for await tokenData in Activity<PrintActivityAttributes>.pushToStartTokenUpdates {
                    guard let self else { return }
                    // `icon_uri` is empty until the brand glyph is written to the App Group (a known
                    // gap); Trellis treats an empty value as "keep what you have" for start tokens.
                    await self.post("/register-start", body: StartRegistration(pushToken: Self.hex(tokenData), iconUri: ""))
                }
            }
        }

        Task { [weak self] in
            for await activity in Activity<PrintActivityAttributes>.activityUpdates {
                guard let self else { return }
                self.observe(activity)
            }
        }
        adoptExistingActivities()
    }

    private func adoptExistingActivities() {
        for activity in Activity<PrintActivityAttributes>.activities { observe(activity) }
    }

    /// Wire one card — ours or the server's — to the streams that keep it honest.
    private func observe(_ activity: Activity<PrintActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        let id = activity.id
        let k = key(printerId: activity.attributes.printerId, amsId: activity.attributes.amsId)

        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self else { return }
                // Only `.dismissed` means the card has actually left the screen. `.ended` still leaves
                // it visible under `.default`, and acting on it would drop the card early.
                if case .dismissed = state { self.cardVanished(activityId: id, key: k) }
            }
        }

        guard isServerOwned else { return }
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard let self else { return }
                let token = Self.hex(tokenData)
                self.tokens[id] = token
                await self.register(activity: activity, token: token)
            }
        }
    }

    private func cardVanished(activityId: String, key k: String) {
        observed.remove(activityId)
        tokens[activityId] = nil
        registered = registered.filter { !$0.hasPrefix("\(activityId)|") }
        lastRegisterAttempt = lastRegisterAttempt.filter { !$0.key.hasPrefix("\(activityId)|") }
        // We ended this one ourselves, so its disappearance carries no instruction from the user.
        guard endedByApp.remove(activityId) == nil else { return }
        dismissed.insert(k)
        lastContent[k] = nil
        lastUpdate[k] = nil
    }

    // MARK: - Trellis registration

    /// `POST /register-start` — the device's push-to-start token.
    struct StartRegistration: Encodable, Equatable {
        let pushToken: String
        let iconUri: String
        /// Which phone. Without it two devices sharing one Bambuddy key are indistinguishable to
        /// Trellis, so one phone's reconcile deregisters the other's cards.
        var deviceId: String = ""
        /// The Canopy claim, forwarded verbatim. Absent when the server signs locally.
        var claim: ClaimBuilder.Claim? = nil
        /// Constant, so it stays out of the memberwise init and cannot be forgotten at a call site.
        let client = laPushClient
    }

    /// `POST /register` — binds one card's APNs update token so the server can push into it.
    struct CardRegistration: Encodable, Equatable {
        let printerId: Int
        let pushToken: String
        let printerName: String
        let iconUri: String
        /// `"print"` | `"dry"`. Trellis keys drying cards `dry:<printerId>:<amsId>` off THIS field, so
        /// a drying card registered as a print overwrites the print card's registration instead.
        let kind: String
        let amsId: Int?
        /// Which phone — see StartRegistration.deviceId.
        var deviceId: String = ""
        /// The Canopy claim, forwarded verbatim — see StartRegistration.claim.
        var claim: ClaimBuilder.Claim? = nil
        /// Constant, so it stays out of the memberwise init and cannot be forgotten at a call site.
        let client = laPushClient
    }

    /// Pure: what a card says about itself → the body Trellis wants.
    ///
    /// The name and glyph are echoed from the card's OWN content rather than from anything the app has
    /// cached, because `/register` overwrites both server-side: in SERVER mode this card was created
    /// by Trellis, and posting the app's idea of the name would blank a title the server got right.
    nonisolated static func cardRegistration(
        attributes: PrintActivityAttributes,
        state: PrintActivityAttributes.ContentState,
        token: String,
        deviceId: String = "",
        claim: ClaimBuilder.Claim? = nil
    ) -> CardRegistration {
        CardRegistration(
            printerId: attributes.printerId,
            pushToken: token,
            printerName: state.printerName,
            iconUri: state.iconUri,
            kind: attributes.amsId == nil ? "print" : "dry",
            amsId: attributes.amsId,
            deviceId: deviceId,
            claim: claim
        )
    }

    /// Re-attempt registrations that have not been accepted yet. A card whose token never reached
    /// Trellis is a card frozen at the content it was created with — the "stuck at 0 %" symptom — and
    /// the token stream will not re-emit just because a POST failed.
    private func flushRegistrations() async {
        for activity in Activity<PrintActivityAttributes>.activities {
            guard let token = tokens[activity.id] else { continue }
            await register(activity: activity, token: token)
        }
    }

    private func register(activity: Activity<PrintActivityAttributes>, token: String) async {
        guard isServerOwned, !token.isEmpty else { return }
        let pair = "\(activity.id)|\(token)"
        guard !registered.contains(pair) else { return }
        if let last = lastRegisterAttempt[pair], Date().timeIntervalSince(last) < Self.registerRetry { return }
        lastRegisterAttempt[pair] = Date()

        let body = Self.cardRegistration(attributes: activity.attributes, state: activity.content.state, token: token)
        if await post("/register", body: body) { registered.insert(pair) }
    }

    /// Trellis endpoint for `path`, or nil when push is off. Trailing slashes are stripped because
    /// `…/` + `/register` is `//register`, which the server 404s.
    nonisolated static func endpoint(_ base: String?, _ path: String) -> URL? {
        guard var base = base else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return URL(string: base + path)
    }

    /// The JSON shape Trellis's pydantic models expect: snake_case, nil optionals omitted.
    nonisolated static func encode(_ body: some Encodable) -> Data? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try? encoder.encode(body)
    }

    nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// POST a registration body. Returns whether Trellis accepted it.
    ///
    /// The status code is checked rather than discarded: this app spent a release posting to a route
    /// that did not exist, and a swallowed 404/422 looks exactly like success from in here.
    @discardableResult
    private func post(_ path: String, body: some Encodable) async -> Bool {
        guard let url = Self.endpoint(pushUrl, path), let data = Self.encode(body) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = data
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

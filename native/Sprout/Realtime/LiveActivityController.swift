#if os(iOS)
// ActivityKit does not exist on macOS. The menu bar extra (1b) is the Mac answer (§6).
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
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
    /// Tokens the relay has told us it cannot push to (`needs_claim`). Not a diagnostic: while a
    /// token is in here the SERVER cannot write that card, so this app must — see `appMustWrite`.
    private var unbound: Set<String> = []
    private var lastRegisterAttempt: [String: Date] = [:]

    /// Minimum gap between updates for one card. ActivityKit throttles aggressively and a card that
    /// updates every status frame gets its budget cut.
    private static let throttle: TimeInterval = 4
    /// Minimum gap between registration attempts for one (card, token) pair. `sync` runs every 4 s and
    /// an unreachable Trellis must not turn that into a POST storm.
    private static let registerRetry: TimeInterval = 30
    /// How long after launch reconcile stays silent about activities it holds no token for.
    ///
    /// Long enough that `pushTokenUpdates` and `adoptExistingActivities` have both had their say —
    /// they deliver within moments — and short enough that an orphaned card is ended in the same
    /// minute rather than living beside its replacement.
    private static let adoptionGrace: TimeInterval = 20
    /// When each still-untracked activity was first seen without a token, for `adoptionGrace`.
    ///
    /// Per ACTIVITY rather than per process: an orphan that has been tokenless for hours is one we
    /// can report immediately, and only a card that appeared moments ago deserves the wait.
    private var untrackedSince: [String: Date] = [:]

    var isServerOwned: Bool { pushUrl != nil }

    /// This device's durable identity — what owns every push binding this phone holds.
    ///
    /// Resolved lazily and RETRIED while nil, not fixed at init. It used to be a `let` assigned with
    /// `try?`, and the failure that mattered was invisible: iOS grants this app background runtime
    /// while the phone is locked — a push-to-start in a pocket is the canonical case — and a Keychain
    /// read then fails with `errSecInteractionNotAllowed`. `try?` turned that into nil, and because
    /// it was a `let`, nil for the entire lifetime of the process. Every registration that process
    /// went on to make was sent unclaimed, so the relay accepted it and refused to push to it, and
    /// the card the push-to-start had just created froze at its opening state for the whole print.
    /// Unlocking the phone did not help: the value was already decided.
    ///
    /// Measured against the author's own server before this fix: ~1000 registrations produced 14
    /// claims, the 14 being processes that happened to start while the phone was unlocked.
    ///
    /// Still never regenerates. A locked Keychain THROWS from `load()` rather than reporting the
    /// item absent, so `loadOrCreate` cannot mistake "cannot read it yet" for "there isn't one" and
    /// mint a second identity that orphans every binding this phone holds.
    private var resolvedIdentity: PairingIdentity?
    private var identity: PairingIdentity? {
        if let resolvedIdentity { return resolvedIdentity }
        resolvedIdentity = try? PairingStore.loadOrCreate()
        return resolvedIdentity
    }
    /// Registrations still owed to the server, across all three token kinds.
    private var pending = PendingClaims()

    /// Whether this device can prove itself to the relay — read by Settings.
    ///
    /// Exists because the failure it reports is otherwise completely silent. A registration sent
    /// without a claim is ACCEPTED by the relay and then never pushed to, so every component reports
    /// success and the only symptom is a lock-screen card that never moves. One install spent hours
    /// that way. This repo's rule is that an absent capability says so rather than being discovered
    /// by hitting it.
    enum ClaimHealth: Equatable, Sendable {
        /// Nothing to prove yet — push is off, or no token has needed a claim.
        case idle
        /// The last claim was built and accepted.
        case ok
        /// The last claim could not be built. Registrations are going out unclaimed.
        case unclaimed(String)

        /// Copy for Settings. States what is wrong and what it costs, never a stack trace.
        var message: String? {
            switch self {
            case .idle, .ok: nil
            case .unclaimed(let why): why
            }
        }
    }

    /// Last known claim health. Written by `buildClaim` and the registration paths.
    private(set) var claimHealth: ClaimHealth = .idle

    init(config: AppConfig) {
        pushUrl = ConfigRules.resolvePushUrl(config)
        apiKey = config.apiKey
        // Not assigned here: see `identity`. A read that fails because the phone is locked must be
        // retried, not frozen into the process.
        startObserving()
    }

    private static var instance: LiveActivityController?

    /// The one controller this process has, built on demand.
    ///
    /// **Why this is not just a convenience.** Apple's contract for a push-to-started card is that
    /// the system "starts a new Live Activity, wakes up your app, and grants it background runtime",
    /// and that "while the system starts the new Live Activity and wakes up your app, you receive
    /// the push token you use for updates". That token is the ONLY way anyone can update that card.
    ///
    /// It was arriving to nobody. The controller — the only object that iterates `pushTokenUpdates`
    /// — was built inside `AppModel.connect`, which runs from the SwiftUI scene's `.task`, and a
    /// background launch never builds a scene. So iOS did exactly what it promises, handed the token
    /// to a process with no listener in it, and the card stayed frozen at its start content until
    /// somebody opened the app by hand. Thirteen days of that on one deployment, every print.
    ///
    /// So the app delegate builds it at launch — every launch, including the invisible ones — and
    /// the session reuses that instance rather than making a second one. Two controllers would mean
    /// two registrations for one card and, since the app now writes cards the relay cannot reach,
    /// two writers.
    @discardableResult
    static func shared(config: AppConfig) -> LiveActivityController {
        if let instance, instance.pushUrl == ConfigRules.resolvePushUrl(config), instance.apiKey == config.apiKey {
            return instance
        }
        // Settings → Save changes where registrations go, so the old one is replaced rather than
        // reconfigured. Its stream tasks hold `self` weakly and end with it.
        let controller = LiveActivityController(config: config)
        instance = controller
        return controller
    }

    /// The device id sent with every registration, so Trellis can tell two phones apart. They share
    /// one Bambuddy key, so without this one phone's reconcile deregisters the other's cards.
    private var deviceID: String { identity?.deviceID ?? "" }

    /// App Attest, shared across claims so one key is attested and then asserted with.
    private let attestor = AttestClient()

    /// When we last reported our cards to Trellis.
    private var lastReconcile: Date?

    /// How often to reconcile. The 4-second tick drives it, but the set of cards this device can see
    /// changes only when one appears or disappears, so a round trip per tick would be waste.
    private static let reconcileInterval: TimeInterval = 30

    /// Builds the claim a registration carries, or nil when the server signs locally and needs none.
    ///
    /// Returns nil rather than throwing on any failure: a claim that cannot be built must degrade to
    /// the pre-relay behaviour, not take the registration down with it. A relay-mode server refuses
    /// an unclaimed registration itself, which is where that decision belongs.
    private func buildClaim(token: String, kind: ClaimBuilder.BindingKind, vouchNonce: String?) async -> ClaimBuilder.Claim? {
        // Every failure here is logged. A claim that silently comes back nil produces a
        // registration the relay accepts and then refuses to push to — the exact shape of failure
        // this project keeps rediscovering, where every component reports success and the card
        // never updates.
        guard let identity else {
            NSLog("[claim] no pairing identity; registration will go out unclaimed")
            // Almost always a Keychain read refused because the phone is locked. It heals by itself
            // on the next attempt after an unlock, so the copy says "waiting", not "broken".
            claimHealth = .unclaimed("Waiting for this iPhone to be unlocked. Lock-screen cards start updating once it has been unlocked at least once since it restarted.")
            return nil
        }
        guard attestor.isSupported else {
            NSLog("[claim] App Attest unsupported on this device; registration will go out unclaimed")
            claimHealth = .unclaimed("This device can't use App Attest, so the relay can't verify it. Lock-screen cards won't update while the app is closed.")
            return nil
        }
        // Reserve the proof kind first: the challenge must be requested for the purpose the claim
        // will actually answer with, and the relay checks they agree.
        let plan = await attestor.planProof()
        guard let challenge = await fetchChallenge(attesting: plan == .attestation) else {
            NSLog("[claim] could not obtain a challenge; registration will go out unclaimed")
            claimHealth = .unclaimed("Couldn't reach Trellis to verify this device. Check the Trellis URL in Push, and that Trellis is running.")
            return nil
        }

        let builder = ClaimBuilder(
            identity: identity,
            environment: APNSEnvironment.current,
            sign: { try PairingStore.sign($0) },
            attest: { [attestor] data in try await attestor.proof(for: data) }
        )
        do {
            let claim = try await builder.build(token: token, kind: kind, challenge: challenge, vouchNonce: vouchNonce)
            // **The success path never said so.** `claimHealth` was written by all three `guard`
            // failures above and by nothing else, so `.ok` had zero writers: once a device had failed
            // to claim, the readout kept reporting that failure through every later success, and a
            // recovered device looked permanently broken. The three failures are only three quarters
            // of the outcomes.
            claimHealth = .ok
            return claim
        } catch {
            NSLog("[claim] build failed for %@ token: %@", kind.rawValue, String(describing: error))
            claimHealth = .unclaimed("This device couldn't prove itself to Trellis. Push will keep working if it is already bound; a fresh install may need Trellis restarted.")
            return nil
        }
    }

    /// Fetches a single-use challenge from the relay, through Trellis.
    ///
    /// The purpose has to match what the proof will be, because the relay checks it: an attestation
    /// challenge lives fifteen minutes to honour Apple's retry guidance, an assertion challenge two,
    /// and letting one satisfy the other would stretch the assertion replay window sevenfold.
    private func fetchChallenge(attesting: Bool) async -> String? {
        guard let url = ConfigRules.trellisEndpoint(pushUrl, "/challenge") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["purpose": attesting ? "attestation" : "assertion"]
        )

        guard
            let (data, response) = try? await URLSession.shared.data(for: req),
            // Any 2xx. Trellis is a proxy here and answers with ITS status, not the relay's —
            // checking for the relay's 201 meant every challenge fetch failed against a Trellis
            // that had done its job perfectly, and the registration then went out unclaimed.
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let challenge = body["challenge"] as? String
        else { return nil }
        return challenge
    }

    // MARK: - Content mapping
    //
    // These are pure functions over value types, so they are `nonisolated`: they carry no instance
    // state, and forcing callers onto the main actor to compute a struct would be noise.

    /// Theme-independent tint for a print card, derived from the semantic state rather than a themed
    /// colour, so the same print looks identical whoever built the card.
    nonisolated static func tint(_ vm: DashVM) -> String {
        // Delegated, not re-derived. The Mac menu bar picks a GLYPH from the same ladder, and two
        // switches over the same inputs written a month apart is how the phone ends up saying
        // "paused" while the Mac says "printing" about one machine. See `LAState`.
        LAState.of(vm: vm).tintHex
    }

    nonisolated private static let symbols: [String: String] = [
        // Layers stacking upward, which is what an FDM machine actually does. `printer.fill`
        // is a sheet-fed office printer and read as the wrong appliance entirely.
        "Printing": "square.stack.3d.up.fill",
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
        // Which plate, so the WIDGET can derive the image's file name when a Trellis push blanks
        // `modelUri`. Read from the status here rather than passed in: `content` already has the
        // status and this is the same answer `AppModel` gives the resolver.
        s.plate = PrintArt.plateIndex(
            gcodeFile: status.gcodeFile, currentPlateId: status.currentPlateId?.int)
        s.archiveId = status.currentArchiveId
        s.queueCount = queueCount
        s.nextName = nextName
        s.name = status.subtaskName ?? ""
        s.stateLabel = vm.stateLabel
        s.progress = vm.progressInt
        s.layer = status.layerNum?.int ?? 0
        s.totalLayers = status.totalLayers?.int ?? 0
        s.etaEpochMs = (!finished && remainingMin > 0) ? now.addingTimeInterval(remainingMin * 60).timeIntervalSince1970 * 1000 : 0
        s.finished = finished
        s.symbol = symbols[vm.stateLabel] ?? (vm.kind == .error ? "exclamationmark.triangle.fill" : "square.stack.3d.up.fill")
        s.tint = tint(vm)
        s.nozzle = Int((t?.nozzle?.double ?? 0).rounded())
        s.nozzleTarget = Int((t?.nozzleTarget?.double ?? 0).rounded())
        s.nozzle2 = Int((t?.nozzle2?.double ?? 0).rounded())
        s.nozzle2Target = Int((t?.nozzle2Target?.double ?? 0).rounded())
        s.hasNozzle2 = dual
        s.activeNozzle = activeNozzle
        s.bed = Int((t?.bed?.double ?? 0).rounded())
        s.bedTarget = Int((t?.bedTarget?.double ?? 0).rounded())
        // Enclosed machines only, and PRESENCE is the test — the same one `DashVM.hasChamber` uses,
        // so the card and the dashboard cannot disagree about whether this printer has a chamber.
        // Target is set inside the same branch: a machine with no chamber can never show a chamber
        // it is heating to.
        if let chamber = t?.chamber {
            s.chamber = Int((chamber.double ?? 0).rounded())
            s.chamberTarget = Int((t?.chamberTarget?.double ?? 0).rounded())
        }
        return s
    }

    /// One card's identity and liveness, for `supersededCardIds`.
    struct CardLiveness: Equatable, Sendable {
        let id: String
        /// `key(printerId:amsId:)` — the card's identity, not the activity's.
        let identity: String
        /// `activityState == .active`: iOS will still let this card be updated.
        let isLive: Bool
    }

    /// Cards iOS has finished with WHILE a live card for the same printer exists.
    ///
    /// **A Live Activity may only be updated for eight hours** (HIG, Live Activities: "work best for
    /// tracking short to medium duration activities that don't exceed eight hours"). At that mark
    /// iOS ends the activity and its push token starts answering APNs `410`, but the card stays on
    /// the Lock Screen "for up to four hours" more. Trellis reads the 410 correctly — it can no
    /// longer drive that card — and pushes a replacement, so a print longer than eight hours shows
    /// TWO cards: one frozen at the layer it reached at the eight-hour mark, one live. Measured:
    /// registered 22:49:15, `410` at 06:49:52, 8h 00m 37s.
    ///
    /// Only the app can clear the frozen one. Ending is a local call and works with a dead token,
    /// while the only push that could end it would have to travel through the token that just died.
    ///
    /// The predicate is **superseded**, not "ended". A card that ends with nothing to replace it is
    /// a finished print, and its card should linger exactly as it does now — that is the whole point
    /// of the four hours. Ending on `.ended` alone would snatch away every completed print's card.
    nonisolated static func supersededCardIds(_ cards: [CardLiveness]) -> [String] {
        let liveIdentities = Set(cards.filter(\.isLive).map(\.identity))
        return cards.filter { !$0.isLive && liveIdentities.contains($0.identity) }.map(\.id)
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

    /// **Two or more units drying collapse into ONE card.**
    ///
    /// Three drying-capable units are fitted, so three concurrent cycles is ordinary — and one card
    /// each plus the print card is four cards for a single machine, which buries the print under the
    /// thing that matters least. iOS orders the lock-screen stack by start time and that is not
    /// controllable, so the only lever is how many cards exist.
    ///
    /// One unit keeps its own card: an aggregate of one is a worse version of the card it replaces.
    nonisolated static let aggregateDryingThreshold = 2

    /// The aggregate card's content, or nil when fewer than two units are drying.
    ///
    /// Rows sort by time remaining, soonest first, and the HEADLINE is the LONGEST — the two answer
    /// different questions and the header's is "when is the whole batch done".
    nonisolated static func aggregateDryContent(
        _ status: PrinterStatus,
        now: Date = Date(),
        printerName: String = "",
        iconUri: String = ""
    ) -> PrintActivityAttributes.ContentState? {
        let units = status.ams ?? []
        let drying = units.filter { ($0.dryTime?.double ?? 0) > 0 }
        guard drying.count >= aggregateDryingThreshold else { return nil }

        let rows = drying.map { ams -> PrintActivityAttributes.DryUnitState in
            let isHt = ams.isAmsHt == true || ams.id >= 128
            return PrintActivityAttributes.DryUnitState(
                amsId: ams.id,
                label: isHt ? "AMS HT" : "AMS \(ams.id + 1)",
                filament: ams.dryFilament?.isEmpty == false ? ams.dryFilament! : "Filament",
                temp: Int((ams.temp?.double ?? 0).rounded()),
                target: Int((ams.dryTargetTemp?.double ?? 0).rounded()),
                humidity: Int((ams.humidity?.double ?? 0).rounded()),
                minutesLeft: Int((ams.dryTime?.double ?? 0).rounded())
            )
        }
        .sorted { $0.minutesLeft < $1.minutesLeft }

        var s = PrintActivityAttributes.ContentState()
        s.printerName = printerName
        s.iconUri = iconUri
        s.dry = true
        s.stateLabel = "Drying"
        s.name = "\(rows.count) units"
        s.tint = LAColors.drying
        s.symbol = "humidity.fill"
        s.finished = false
        s.progress = 0
        // The LONGEST, not the soonest: the card answers "when is the batch done".
        let longest = rows.map(\.minutesLeft).max() ?? 0
        s.etaEpochMs = now.addingTimeInterval(Double(longest) * 60).timeIntervalSince1970 * 1000
        s.dryUnits = rows
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
            || a.dryUnits != b.dryUnits
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
            // Presence first: a chamber APPEARING is a change even when its reading rounds to the
            // same number, and `(nil ?? 0)` would compare equal to a real 0° and never push.
            || (a.chamber == nil) != (b.chamber == nil)
            || abs((a.chamber ?? 0) - (b.chamber ?? 0)) >= 2
            || (a.chamberTarget ?? 0) != (b.chamberTarget ?? 0)
            // A new plate is a new PICTURE, and the widget derives that picture's path from this
            // field — so a state whose only change is the plate still has to reach the card.
            || a.plate != b.plate
            || a.archiveId != b.archiveId
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
    /// `iconUri` / `modelUri` are resolved by the CALLER (`LiveActivityArtResolver`, via `AppModel`)
    /// and passed in as plain strings. They are not fetched here on purpose: the images need the
    /// library listing and a camera token, and giving this controller a network client would make the
    /// card subsystem depend on the browsing subsystem to draw a thumbnail.
    /// The brand glyph's App Group URI, handed down by `AppModel` and remembered.
    ///
    /// Registration happens on paths that have no `sync` arguments in scope — `/register-start` fires
    /// from a token stream and `flushPending` from a retry queue — so the value has to be held rather
    /// than threaded. Both used to post `iconUri: ""` with a comment calling it a known gap, and that
    /// gap is why the new App Group artwork would have reached nothing in SERVER mode, which is the
    /// shipping configuration: Trellis owns the card there, and it renders what registration gave it.
    private(set) var glyphUri: String = ""

    func sync(
        printerId: Int,
        printerName: String,
        vm: DashVM,
        status: PrinterStatus?,
        iconUri: String = "",
        modelUri: String = ""
    ) async {
        // Remembered for the registration paths, which run outside this call.
        if !iconUri.isEmpty { glyphUri = iconUri }
        // Cards also appear without us: in SERVER mode Trellis starts them remotely, and cards from a
        // previous launch outlive the process. Sweeping here — not only from `activityUpdates`, whose
        // replay of already-live activities is not something to bet a subsystem on — is what
        // guarantees every card ends up wired to its dismissal and push-token streams.
        adoptExistingActivities()

        // Deliberately not awaited: this loop runs every 4 s and also drives the cooldown readout, so
        // a slow Trellis must not stall it. `lastRegisterAttempt` is stamped BEFORE the request, so an
        // overlapping flush cannot double-POST.
        // `identity != nil` gates both flushes. Without an identity a registration cannot carry a
        // claim, and the relay states what it does with those: "registered WITHOUT a claim; it
        // cannot be pushed to until the device claims it". So the POST buys nothing — and it costs
        // something, because `deviceID` is derived from the identity and goes out EMPTY, which is
        // exactly the case the field exists to prevent (two phones on one Bambuddy key become
        // indistinguishable and one phone's reconcile deregisters the other's cards).
        //
        // The usual reason it is nil is a locked phone, so this is a wait, not a failure: `identity`
        // retries the Keychain read on every access and the flush resumes the moment it succeeds.
        // Measured before this guard: ~200 registrations against 13 claims over an hour, the other
        // ~190 being unclaimed POSTs repeating every 33 s for the life of the process.
        let canClaim = identity != nil

        if isServerOwned, canClaim, !tokens.isEmpty { Task { [weak self] in await self?.flushRegistrations() } }
        // The queue covers the registrations that have no stream to re-emit them: a start or
        // device token is handed over once, so a POST that failed is otherwise the end of it, and
        // the server is left with nothing to push a start to for the rest of the process.
        if isServerOwned, canClaim, !pending.isEmpty { Task { [weak self] in await self?.flushPending() } }
        // Reconcile even with no tokens held: "this device now sees no cards" is exactly the report
        // that frees a ghost registration, and gating it on a non-empty set would withhold the one
        // message that matters most.
        Task { [weak self] in await self?.reconcile() }

        guard let status else { return }
        guard vm.kind != .offline, vm.kind != .connecting else { return }

        let shouldHavePrintCard = vm.kind == .live || vm.kind == .complete || vm.kind == .error
        let printState = Self.content(vm: vm, status: status, printerName: printerName,
                                      iconUri: iconUri, modelUri: modelUri)

        if shouldHavePrintCard {
            await upsert(printerId: printerId, amsId: nil, content: printState, ended: vm.kind == .complete)
        } else {
            await end(printerId: printerId, amsId: nil)
        }

        // One card per drying unit — a per-printer key silently hid the second concurrent cycle.
        // Which drying cards SHOULD exist right now: either one per unit, or one aggregate standing
        // in for all of them. Computed as a set first so the sweep below has one thing to compare
        // against — an aggregate that appears must also end the per-unit cards it replaced, and a
        // batch dropping back to one unit must end the aggregate.
        var wanted = Set<Int>()
        if let aggregate = Self.aggregateDryContent(status, printerName: printerName, iconUri: iconUri) {
            wanted.insert(PrintActivityAttributes.aggregateAmsId)
            await upsert(printerId: printerId,
                         amsId: PrintActivityAttributes.aggregateAmsId,
                         content: aggregate, ended: false)
        } else {
            for unitId in Set(Self.dryingUnitIds(status)) {
                if let dry = Self.dryContent(status, amsId: unitId, printerName: printerName, iconUri: iconUri) {
                    wanted.insert(unitId)
                    await upsert(printerId: printerId, amsId: unitId, content: dry, ended: false)
                }
            }
        }
        let drying = wanted
        for activity in Activity<PrintActivityAttributes>.activities {
            if let amsId = activity.attributes.amsId,
               activity.attributes.printerId == printerId,
               !drying.contains(amsId) {
                await end(printerId: printerId, amsId: amsId)
            }
        }
    }

    /// Whether this app has to write a card the server nominally owns.
    ///
    /// A Live Activity started by push can only be updated through ITS OWN token, and ActivityKit
    /// hands that token to a running process and to nobody else. When the app is force-quit iOS
    /// never launches it, the token never reaches Trellis, and the relay refuses every update as
    /// `not_bound` — so the card sits frozen at the percentage the start push created, with its ETA
    /// counting down on the device and nothing anywhere reporting a failure. Thirteen days of that
    /// went unnoticed on a real deployment.
    ///
    /// The single-writer rule survives, because ownership only moves once the server has SAID it is
    /// not the writer: an unregistered pair (Trellis never answered `bound`) or a token it has since
    /// listed in `needs_claim`. There is no window where both sides believe they own the card.
    nonisolated static func appMustWrite(token: String?, registered: Bool, unbound: Bool) -> Bool {
        guard let token, !token.isEmpty else { return true }  // nothing was ever handed over
        return unbound || !registered
    }

    /// `appMustWrite` for the card under one key. False when no card exists: creating one in SERVER
    /// mode stays push-to-start's job, or two cards appear for one print.
    private func serverCannotWrite(printerId: Int, amsId: Int?) -> Bool {
        for activity in Activity<PrintActivityAttributes>.activities
        where activity.attributes.printerId == printerId && activity.attributes.amsId == amsId {
            let token = tokens[activity.id]
            return Self.appMustWrite(
                token: token,
                registered: token.map { registered.contains("\(activity.id)|\($0)") } ?? false,
                unbound: token.map { unbound.contains($0) } ?? false
            )
        }
        return false
    }

    private func upsert(printerId: Int, amsId: Int?, content: PrintActivityAttributes.ContentState, ended: Bool) async {
        // SERVER mode: the server is the sole WRITER as well as the sole creator, so this returns
        // before touching a card or the gate state behind it. Two writers do not merely halve the
        // ActivityKit budget — Trellis pushes off a 5 s poll while the app reads a socket, so the two
        // hold different snapshots and the card's progress visibly jitters backwards. The local gate
        // (`lastContent`/`lastUpdate`) also knows nothing about what the server last rendered, so the
        // two sides cannot even agree on what counts as a change.
        //
        // Unless the server cannot write it at all, which is not the same question — see
        // `appMustWrite`. A card only this app can reach is a card only this app can keep honest.
        guard !isServerOwned || serverCannotWrite(printerId: printerId, amsId: amsId) else { return }

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

        // No card exists, so this is a creation — and creation is push-to-start's job in SERVER
        // mode even when the app has taken over WRITING. Creating one here would put a second card
        // on the lock screen the moment a start push landed.
        guard !isServerOwned else { return }
        // Respect a swipe: the user removing a card is an instruction, not a glitch to heal.
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
                    let token = Self.hex(tokenData)
                    // Queued as well as sent. This stream only re-emits when the token rotates, so
                    // a POST that failed here used to be the end of it: the server then had nothing
                    // to push a start to and the lock screen stayed empty for the whole print.
                    self.pending.add(token: token, kind: .start)
                    // Stamped BEFORE the eager send, so `flushPending` — which runs on the 4 s tick
                    // and honours the same 30 s per-token throttle — does not register this token a
                    // second time while this POST is still in flight. Queuing AND sending is
                    // deliberate (a failed send here would otherwise be the end of it), but without
                    // the stamp both paths fired: two claims, two challenges, two register-starts,
                    // in the same second on the same connection. The card path at `register` and
                    // `flushPending` itself already stamp; this was the one that did not.
                    self.lastRegisterAttempt[token] = Date()
                    // The glyph, when we have one. Trellis treats an empty value as "keep what you
                    // have", so a registration that races the first `sync` is not destructive — the
                    // next one carries it.
                    let claim = await self.buildClaim(token: token, kind: .start, vouchNonce: nil)
                    let result = await self.postWithReason("/register-start", token: token, body: StartRegistration(
                        pushToken: token, iconUri: self.glyphUri, deviceId: self.deviceID, claim: claim
                    ))
                    if result.ok && result.bound {
                        self.pending.remove(token: token)
                        await self.attestor.confirmAttested()
                    } else {
                        await self.handle(refusal: result.reason)
                    }
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

    /// End every card `supersededCardIds` names, immediately.
    ///
    /// `.immediate` and not `.default`: the default policy is what leaves an ended card on the Lock
    /// Screen for four hours, which is the thing being cleaned up. Called from three places because
    /// the moment a card becomes superseded is not a moment anything notifies us of — the old card
    /// ends at the eight-hour mark and its replacement arrives milliseconds later, so whichever of
    /// the two happens second is what makes the pair. Launch, every reconcile, and the arrival of
    /// any new card all re-ask the question; it is a scan of a two-element array.
    private func endSupersededActivities() {
        let all = Activity<PrintActivityAttributes>.activities
        let doomed = Set(
            Self.supersededCardIds(
                all.map {
                    CardLiveness(
                        id: $0.id,
                        identity: key(printerId: $0.attributes.printerId, amsId: $0.attributes.amsId),
                        isLive: $0.activityState == .active)
                }))
        guard !doomed.isEmpty else { return }
        for activity in all where doomed.contains(activity.id) {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func adoptExistingActivities() {
        for activity in Activity<PrintActivityAttributes>.activities { observe(activity) }
        // Anything already on screen at launch has been through `observe`, which reads
        // `activity.pushToken` SYNCHRONOUSLY. So a card still tokenless after this is genuinely
        // tokenless — not one whose token is moments away — and reconcile may report it at once.
        //
        // Without this the per-activity grace restarts every launch: the orphan is "first seen"
        // again each time, waits out the grace again, and a user who opens the app briefly never
        // reaches a `/sync`. Backdating is what makes the very first tick able to end it.
        for activity in Activity<PrintActivityAttributes>.activities where tokens[activity.id] == nil {
            untrackedSince[activity.id] = .distantPast
        }
        // Opening the app is when a user is looking at the duplicate, so clear it here rather than
        // waiting for the first reconcile interval to come round.
        endSupersededActivities()
    }

    /// Wire one card — ours or the server's — to the streams that keep it honest.
    private func observe(_ activity: Activity<PrintActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        // A NEW card arriving is one of the two ways a pair forms — the replacement Trellis pushes
        // when the old card's token starts answering 410.
        defer { endSupersededActivities() }
        let id = activity.id
        let k = key(printerId: activity.attributes.printerId, amsId: activity.attributes.amsId)

        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self else { return }
                // Only `.dismissed` means the card has actually left the screen. `.ended` still leaves
                // it visible under `.default`, and acting on it would drop the card early.
                if case .dismissed = state {
                    self.cardVanished(activityId: id, key: k, printerId: activity.attributes.printerId)
                } else {
                    // The other way a pair forms: THIS card ends (iOS does that at the eight-hour
                    // mark) while a replacement is already live. `.ended` alone still means "leave
                    // it up" — `endSupersededActivities` is what decides, and it needs a live card
                    // for the same printer before it touches anything.
                    self.endSupersededActivities()
                }
            }
        }

        guard isServerOwned else { return }
        // The token a card ALREADY has, read directly. `pushTokenUpdates` is the durable path and
        // stays below, but a card adopted at launch (started remotely while the app was closed) has
        // had its token for some time, and waiting for the stream to re-emit is waiting for a rotation
        // that may not come this print. Registering it is what un-freezes that card.
        if let existing = activity.pushToken.map(Self.hex), !existing.isEmpty, tokens[id] != existing {
            tokens[id] = existing
            Task { [weak self] in await self?.register(activity: activity, token: existing) }
        }
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard let self else { return }
                let token = Self.hex(tokenData)
                self.tokens[id] = token
                await self.register(activity: activity, token: token)
            }
        }
    }

    private func cardVanished(activityId: String, key k: String, printerId: Int) {
        // Captured before the bookkeeping clears it: the server needs the token to scope the drop
        // to this device, and by the end of this function we no longer have it.
        let vanishedToken = tokens[activityId]
        observed.remove(activityId)
        if let vanishedToken { unbound.remove(vanishedToken) }
        tokens[activityId] = nil
        registered = registered.filter { !$0.hasPrefix("\(activityId)|") }
        lastRegisterAttempt = lastRegisterAttempt.filter { !$0.key.hasPrefix("\(activityId)|") }
        // We ended this one ourselves, so its disappearance carries no instruction from the user.
        guard endedByApp.remove(activityId) == nil else { return }
        dismissed.insert(k)
        lastContent[k] = nil
        lastUpdate[k] = nil

        // Tell the server, or it keeps a registration for a card that no longer exists: APNs
        // answers 200 to a push into the void, and because the server refuses to start a card for a
        // key it already holds, no replacement is ever created. That deadlock is how the lock
        // screen ends up empty mid-print. The RN app reconciles via /sync; this one never did.
        if isServerOwned, let token = vanishedToken, !token.isEmpty {
            pending.remove(token: token)
            Task { [weak self] in
                await self?.unregister(printerId: printerId, token: token)
            }
        }
    }

    // MARK: - Reconciliation

    /// `POST /sync` — tell Trellis every card this device can actually see.
    ///
    /// APNs answering 200 does NOT mean a card exists. A card that dies on the phone — swiped away,
    /// or terminated because a new build was installed over the running app — leaves Trellis pushing
    /// into the void while its registry still claims the card is ours, and because it refuses to
    /// start a card for a key it already holds, no replacement is ever created. The lock screen then
    /// stays empty for the rest of the print. Observed exactly that way.
    ///
    /// `unregister` covers the one case the app witnesses (a dismissal it saw). This covers the ones
    /// it cannot: an activity that vanished while the process was dead has no dismissal callback to
    /// fire, so the only way the truth ever reaches Trellis is the app stating the full set.
    ///
    /// The reply carries two instructions back:
    ///   * `end` — tokens Trellis has nothing to bind to. Ending them stops a card that can never
    ///     update from sitting on the lock screen looking live.
    ///   * `needs_claim` — tokens the relay cannot push to. Intersected against what this device
    ///     actually holds before acting: read as a list of tokens to claim, it would be an
    ///     attestation oracle, letting a compromised server name another user's token and have this
    ///     device sign a valid claim for it.
    struct SyncReport: Encodable, Equatable {
        let tokens: [String]
        let deviceId: String
        /// Never omitted. A card adopted through /sync is pushed to with this client's payload
        /// shape, and an expo-shaped start reaches a native widget as a push APNs accepts and the
        /// phone shows no card for.
        let client = "native"
    }

    struct SyncReply: Decodable, Equatable {
        var end: [String] = []
        var needsClaim: [String] = []

        enum CodingKeys: String, CodingKey {
            case end
            case needsClaim = "needs_claim"
        }

        /// Written out rather than synthesised. A property default does NOT make a key optional to
        /// Swift's generated decoder — it throws keyNotFound — so against a Trellis that omits
        /// either field the whole reply would fail to decode and the ghost-card reconcile, the more
        /// valuable half, would go down with the field it had never heard of.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            end = try c.decodeIfPresent([String].self, forKey: .end) ?? []
            needsClaim = try c.decodeIfPresent([String].self, forKey: .needsClaim) ?? []
        }

        init(end: [String] = [], needsClaim: [String] = []) {
            self.end = end
            self.needsClaim = needsClaim
        }
    }

    /// Reconcile with Trellis. Rate-limited: this is driven by the 4-second tick and costs a round
    /// trip, while the state it reports changes only when a card appears or disappears.
    private func reconcile() async {
        guard isServerOwned else { return }
        // Never reconcile without a device id. `/sync` is how this device tells Trellis which cards
        // it still holds, and Trellis scopes that answer BY device id — so a report carrying an
        // empty one is read as some other device saying "I hold nothing", and the live card is
        // deregistered. That is not theoretical: it emptied the registry and left no Live Activity
        // at all, because `p2s_started` then considers the card already started and will not push
        // another for the same print.
        //
        // Empty means the Keychain could not be read yet (locked phone). Saying nothing is correct
        // there; the next tick after an unlock reports properly.
        guard !deviceID.isEmpty else { return }
        if let last = lastReconcile, Date().timeIntervalSince(last) < Self.reconcileInterval { return }
        lastReconcile = Date()

        // Never report a token set we have not finished assembling.
        //
        // `/sync` is CONVERGENT: Trellis drops any registration whose token is absent from this
        // report, which is correct when the app has genuinely lost a card and fatal when it simply
        // has not looked yet. `tokens` is our own cache, filled by `pushTokenUpdates` and
        // `adoptExistingActivities`; at launch those have not emitted, so an early reconcile says
        // "I see no cards" about a card that is live on the lock screen — and Trellis believes it.
        //
        // Observed: opening the app mid-print took `registrations` from 1 to 0 in one `/sync`, and
        // the pushes stopped because there was nothing left to push to.
        //
        // So the question is not "do I hold tokens" but "do I hold one for every activity
        // ActivityKit says exists" — BOUNDED BY TIME, which the first version of this guard was not
        // and which cost a duplicate card.
        //
        // Waiting forever deadlocks the repair it was meant to protect. A card the app never
        // adopted has no token and never gets one, so `untracked` stays non-empty, reconcile never
        // runs — and `/sync` is exactly what ends an orphaned card, by returning it in `end`.
        // Observed: a stale drying card sat on the lock screen beside its live replacement, zero
        // syncs in thirty minutes, and nothing could ever clear it.
        //
        // So: say nothing while adoption is plausibly still in flight, then speak. By `adoptionGrace`
        // the streams have long since delivered anything they were going to, and a still-untracked
        // activity is not a card we are about to learn about — it is one that needs ending.
        let now = Date()
        let untracked = Activity<PrintActivityAttributes>.activities.filter { tokens[$0.id] == nil }
        for a in untracked where untrackedSince[a.id] == nil { untrackedSince[a.id] = now }
        untrackedSince = untrackedSince.filter { id, _ in untracked.contains { $0.id == id } }
        // Wait only on activities that are PLAUSIBLY still adopting — measured per activity, not
        // per process. Measuring from launch made the app silent for the first 20 seconds of every
        // foreground session, which is most of them: reconcile only runs while the app is on
        // screen, so "open it, glance, close" never reached a single `/sync`. Observed: three hours,
        // zero syncs, while registrations kept arriving because those come from the token STREAMS
        // and not from this tick.
        let stillArriving = untracked.contains { now.timeIntervalSince(untrackedSince[$0.id] ?? now) < Self.adoptionGrace }
        guard !stillArriving else { return }

        let held = Set(tokens.values.filter { !$0.isEmpty })
        let (outcome, payload) = await send("/sync", body: SyncReport(tokens: Array(held), deviceId: deviceID))
        if let line = PostOutcome.logLine(path: "/sync", token: nil, outcome: outcome) { NSLog("%@", line) }

        guard outcome.ok, let payload,
              let reply = try? JSONDecoder().decode(SyncReply.self, from: payload)
        else { return }

        await endOrphans(reply.end, held: held)
        reclaim(reply.needsClaim, held: held)
    }

    /// End cards Trellis has nothing to bind to. Intersected against held tokens for the same reason
    /// the claim list is: the server names tokens, and only ours are ours to act on.
    private func endOrphans(_ orphanTokens: [String], held: Set<String>) async {
        let doomed = Set(orphanTokens).intersection(held)
        guard !doomed.isEmpty else { return }
        for activity in Activity<PrintActivityAttributes>.activities {
            guard let token = tokens[activity.id], doomed.contains(token) else { continue }
            NSLog("[sync] ending orphan card %@", String(token.prefix(8)))
            endedByApp.insert(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Queue a re-claim for tokens the relay cannot push to.
    ///
    /// This is what makes an unbound card recover without a human. `needingReclaim` does the
    /// intersection, and its own test explains why the naive reading is an oracle.
    private func reclaim(_ serverSays: [String], held: Set<String>) {
        for token in pending.needingReclaim(serverSays: serverSays, heldTokens: held) {
            // Recorded, not just retried. Until a claim succeeds the relay will refuse every push to
            // this card, so this app is its only writer — `appMustWrite` reads this set.
            unbound.insert(token)
            // Clearing the stamp lets the next tick retry immediately: the server has just told us
            // this token is unusable, which is newer information than the backoff was protecting.
            registered = registered.filter { !$0.hasSuffix("|\(token)") }
            lastRegisterAttempt = lastRegisterAttempt.filter { !$0.key.hasSuffix("|\(token)") }
            NSLog("[sync] relay cannot push to %@; will re-claim", String(token.prefix(8)))
        }
    }

    /// `POST /unregister` — token-scoped, so one phone dropping its card leaves the other's alone.
    private func unregister(printerId: Int, token: String) async {
        guard let base = pushUrl else { return }
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed + "/unregister") else { return }
        components.queryItems = [
            URLQueryItem(name: "printer_id", value: String(printerId)),
            URLQueryItem(name: "push_token", value: token),
            URLQueryItem(name: "device_id", value: deviceID),
        ]
        guard let url = components.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        _ = try? await URLSession.shared.data(for: req)
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

    /// Re-attempt the queued start and device registrations.
    ///
    /// Rate-limited by the same 30-second per-token backoff as card registrations: this runs on a
    /// 4-second tick, and each attempt costs a challenge and a Secure Enclave signature.
    private func flushPending() async {
        for intent in pending.intents {
            if let last = lastRegisterAttempt[intent.token],
               Date().timeIntervalSince(last) < Self.registerRetry { continue }
            lastRegisterAttempt[intent.token] = Date()

            switch intent.kind {
            case ClaimBuilder.BindingKind.start.rawValue:
                let claim = await buildClaim(token: intent.token, kind: .start, vouchNonce: intent.vouchNonce)
                let result = await postWithReason("/register-start", token: intent.token, body: StartRegistration(
                    pushToken: intent.token, iconUri: glyphUri, deviceId: deviceID, claim: claim
                ))
                if result.ok && result.bound {
                    pending.remove(token: intent.token)
                    await attestor.confirmAttested()
                } else { await handle(refusal: result.reason) }

            case ClaimBuilder.BindingKind.device.rawValue:
                let claim = await buildClaim(token: intent.token, kind: .device, vouchNonce: intent.vouchNonce)
                let result = await postWithReason("/register-device", token: intent.token, body: DeviceRegistration(
                    deviceToken: intent.token, deviceId: deviceID, claim: claim
                ))
                if result.ok && result.bound {
                    pending.remove(token: intent.token)
                    await attestor.confirmAttested()
                } else { await handle(refusal: result.reason) }

            default:
                // Card tokens have their own stream and their own flush; nothing to do here.
                continue
            }
        }
    }

    /// `POST /register-device` — the raw APNs device token, for alert banners.
    ///
    /// Also the only token kind Apple will deliver a silent push to, which makes it the only one
    /// that can be vouched: the relay pushes a nonce to it and the device echoes it back.
    struct DeviceRegistration: Encodable, Equatable {
        let deviceToken: String
        var deviceId: String = ""
        var claim: ClaimBuilder.Claim? = nil
    }

    /// Queue a device token for registration, and re-claim it when a vouch nonce arrives.
    func registerDeviceToken(_ token: String) {
        pending.add(token: token, kind: .device)
        Task { [weak self] in await self?.flushPending() }
    }

    /// The device tokens this install holds. A vouch nonce names no token — it arrives in a push
    /// addressed to one — so it is matched against what this device actually has, never against a
    /// list the server supplied.
    var deviceTokens: [String] {
        pending.intents.filter { $0.kind == ClaimBuilder.BindingKind.device.rawValue }.map(\.token)
    }

    /// A vouch nonce arrived by silent push: attach it and let the next flush spend it. The nonce
    /// is single-use and short-lived, so the retry has to be prompt rather than wait for a rotation.
    func vouchNonceArrived(_ nonce: String, for token: String) {
        pending.attach(nonce: nonce, to: token)
        lastRegisterAttempt[token] = nil  // do not make a fresh proof wait out the backoff
        Task { [weak self] in await self?.flushPending() }
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

        let claim = await buildClaim(token: token, kind: .activity, vouchNonce: nil)
        let body = Self.cardRegistration(
            attributes: activity.attributes, state: activity.content.state,
            token: token, deviceId: deviceID, claim: claim
        )
        // Deliberately NOT queued in `pending`: card tokens are retried by `flushRegistrations`,
        // which walks the live activities, and `flushPending` explicitly skips the `.activity` kind.
        // Adding one here only planted an entry nothing would ever consume or clear.
        let result = await postWithReason("/register", token: token, body: body)
        // Finalised ONLY when the relay can actually push to this token. Trellis answers 200 for a
        // registration it stored but could not bind — which is the normal outcome when App Attest
        // hiccups — and treating that as done leaves the card frozen at its opening content with
        // every component reporting success.
        if result.ok && result.bound {
            registered.insert(pair)
            unbound.remove(token)  // the relay can reach it again; the server is the writer once more
            await attestor.confirmAttested()
        } else {
            // The "why" is already logged by postWithReason, for every failure rather than only
            // this one.
            await handle(refusal: result.reason)
        }
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
    /// POST and surface the server's refusal reason, which some callers must act on: the relay
    /// answering `reattest_required` means it holds no attested key for us, and the only thing that
    /// resolves it is attesting afresh. Treating that as a plain failure would retry an assertion
    /// against a key the relay has never seen, forever.
    /// Posts a registration and reports both questions separately.
    ///
    /// `ok` is "did Trellis store this?" and `bound` is "can the relay actually push to this token?"
    /// They are NOT the same question, and answering the second with the first is what froze a card
    /// for an entire print: a claim that failed to build on the phone still produced a 200, the app
    /// marked the registration final, and nothing retried for the life of the process.
    ///
    /// An absent `bound` field means a Trellis old enough not to answer the question. It is read as
    /// true, because the alternative — retrying forever against a server that signs locally and has
    /// nothing to bind — is a worse failure than the one being fixed.
    /// The one place a Trellis POST is built and its outcome classified.
    ///
    /// There were three of these, differing only in how much they discarded: this one kept a detail
    /// string, `post` kept a Bool, and `reconcile` inlined a fourth copy. All three threw away WHY a
    /// request failed, and none of them logged, which is how a server returning 500 to every
    /// registration stayed invisible on the phone for an entire print.
    private func send(_ path: String, body: some Encodable) async -> (outcome: PostOutcome, payload: Data?) {
        guard let url = ConfigRules.trellisEndpoint(pushUrl, path), let data = Self.encode(body) else {
            return (.misconfigured, nil)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.httpBody = data

        guard let (payload, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return (.unreachable, nil) }

        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            return (.refused(status: http.statusCode, detail: json?["detail"] as? String), payload)
        }
        // Absent `bound` means the endpoint does not bind anything (/sync, /update), not that
        // binding failed — defaulting to false there would retry registrations that are complete.
        return (.stored(bound: json?["bound"] as? Bool ?? true), payload)
    }

    /// Send, and say out loud what happened. `token` is what makes a line attributable when several
    /// cards register on the same tick; endpoints that carry no single token pass nil.
    @discardableResult
    private func postWithReason(_ path: String, token: String? = nil, body: some Encodable) async -> PostOutcome {
        let (outcome, _) = await send(path, body: body)
        if let line = PostOutcome.logLine(path: path, token: token, outcome: outcome) {
            NSLog("%@", line)
        }
        return outcome
    }

    /// Acts on a refusal that the app itself can resolve.
    private func handle(refusal reason: String?) async {
        guard reason == "reattest_required" else { return }
        // The relay holds no public key for ours — a restore that predates this install, not an
        // attack. Discard the key so the next claim carries a fresh attestation.
        NSLog("[claim] relay asked for re-attestation; discarding the local key")
        await attestor.reattest()
    }

    @discardableResult
    private func post(_ path: String, body: some Encodable) async -> Bool {
        await postWithReason(path, body: body).ok
    }
}
#endif

import Foundation
import Observation

// MARK: - Live plug state

/// Live state for one smart plug: a poll loop plus optimistic toggles.
///
/// Shared by the printer's hero control (5 s — the thing you are watching) and each peripheral row
/// (8 s — background devices), so the settle/revert behaviour cannot drift between them.
@MainActor
@Observable
final class PlugPoller {
    private(set) var on = false
    private(set) var reachable = true
    private(set) var watts: Double?
    private(set) var kwh: Double?

    /// The plug this poller is currently bound to. Readable so its owner can tell a genuine re-bind
    /// from a repeat of the one already running.
    private(set) var plugId: Int?

    private let period: Duration
    private var client: BambuddyClient?
    private var task: Task<Void, Never>?

    /// Poll results are DISCARDED until this instant. Bambuddy drives the plug through Home
    /// Assistant, which takes a few seconds to report the new state; without the window the poll
    /// that lands in between is stale and visibly bounces the switch back under the user's finger.
    private var settledUntil: Date = .distantPast
    private static let settleWindow: TimeInterval = 8

    init(period: Duration) {
        self.period = period
    }

    /// Point the poller at a plug on a session.
    ///
    /// Re-binding the SAME plug on the SAME client is a no-op: the running loop, the live numbers and
    /// any settle window in flight all survive a reload that came back with the same strip. Binding
    /// anything different stops the loop, and `PowerStore` starts it again — the job `.task(id:)` did
    /// while this lived on the view, where binding a different plug restarted it and leaving the
    /// screen ended it.
    func bind(client: BambuddyClient?, plugId: Int?) {
        guard client !== self.client || plugId != self.plugId else { return }
        stop()
        self.client = client
        self.plugId = plugId
    }

    /// Poll until `stop()`. Idempotent: a second call keeps the loop that is already running rather
    /// than adding a second one. Does nothing until something is bound.
    func start() {
        guard task == nil, client != nil, plugId != nil else { return }
        let period = self.period
        task = Task { [weak self] in
            // `self` is re-acquired on EVERY pass and never held across the sleep. Binding it once
            // outside the loop turns the weak capture into a strong one for the loop's whole life —
            // and since the loop only exits on cancellation, and the task is owned by the very
            // object it pins, nothing could ever release it. `CooldownStore` learnt this the
            // expensive way, leaking a poller that kept calling the server with a stale client.
            while !Task.isCancelled {
                guard let self, let client = self.client, let plugId = self.plugId else { return }
                await self.poll(client, plugId)
                try? await Task.sleep(for: period)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One poll out of band. Pull-to-refresh re-resolves the plug list, and the live numbers should
    /// refresh with it rather than waiting out the remaining interval.
    func refreshNow() async {
        guard let client, let plugId else { return }
        await poll(client, plugId)
    }

    /// Optimistic write: the switch flips now and holds through the settle window; a rejection
    /// reverts it and reopens polling immediately so the truth comes back without a delay.
    func set(_ next: Bool) async throws {
        guard let client, let plugId else { return }
        on = next
        settledUntil = Date().addingTimeInterval(Self.settleWindow)
        do {
            try await client.plugControl(plugId, on: next)
        } catch {
            settledUntil = .distantPast
            on = !next
            throw error
        }
    }

    private func poll(_ client: BambuddyClient, _ plugId: Int) async {
        do {
            let s = try await client.plugStatus(plugId)
            guard Date() >= settledUntil else { return }
            on = s.state?.uppercased() == "ON"
            reachable = s.reachable ?? false
            watts = finiteNumber(s.energy?.power)
            kwh = finiteNumber(s.energy?.today)
        } catch {
            // A failed status read is exactly what "unreachable" means here — the plug integration
            // is the thing that answers this endpoint.
            reachable = false
        }
    }
}

/// `LooseNumber` turns the literal string `"nan"` these energy fields sometimes carry into a real
/// `Double.nan`, which would render as "nan W". Anything non-finite is absent.
private func finiteNumber(_ n: LooseNumber?) -> Double? {
    guard let v = n?.double, v.isFinite else { return nil }
    return v
}

// MARK: - The printer's own plug

/// The printer's own plug is a three-way answer, and the empty state hangs on telling the cases
/// apart: still-loading must never render "No smart plug linked".
enum PlugSlot: Equatable {
    case loading
    /// No plug bound to this printer. `getPlug` swallows its transport error, so a server that is
    /// simply unreachable also lands here.
    case unlinked
    case linked(SmartPlug)

    var value: SmartPlug? {
        if case .linked(let p) = self { return p }
        return nil
    }
}

// MARK: - One socket

/// One row of the socket list: a plug and the poller bound to it, resolved together so a row can
/// never be rendered without the live numbers that belong to it.
///
/// The pairing used to be implicit — a `@State` poller inside the row view — which is exactly what a
/// second view tree cannot reuse.
struct PlugSocket: Identifiable {
    let plug: SmartPlug
    let poller: PlugPoller
    var id: Int { plug.id }
}

// MARK: - What a tap on a switch means

/// The decision a tap on a plug switch produces, WITHOUT deciding how to ask.
///
/// Switching a plug OFF cuts power — to a running print, to an AMS, to a dryer — so it is confirmed
/// first; switching on is harmless and applies immediately. That rule is data and belongs here. The
/// dialog that carries it is layout, and each platform draws its own.
enum PlugToggleIntent: Equatable, Sendable {
    /// Nothing to switch: no plug is bound yet.
    case ignore
    /// Do it now.
    case apply(Bool)
    /// Ask first — this cuts power.
    case confirmOff
}

// MARK: - Store

/// The Power section's data layer: the printer's own smart plug, every other socket on the strip,
/// the energy tariff those numbers are priced with, and the poll loops that keep all of it live.
///
/// The fetches and the pollers live here rather than inside a view so the iOS Power tab and the Mac
/// Power section drive ONE copy of them. What each platform then draws — the hero control, the stat
/// cards, the automation card, the socket rows — is a pure function of what is loaded here.
///
/// The automations this exposes are deliberately read-only: writes to `/smart-plugs/{id}` are
/// admin-only and 403 with a scoped API key, so the honest thing the app can do is report them
/// accurately.
@Observable
@MainActor
final class PowerStore {

    // MARK: What is loaded

    private(set) var plug: PlugSlot = .loading
    private(set) var allPlugs: [SmartPlug] = []
    private(set) var settings: AppSettings?

    /// Every socket, the printer's own included — `Power.otherPlugs` is passed nil, which keeps it.
    /// All of these are sockets on one physical strip, and hiding the printer's made the strip look
    /// like it was missing one even though that socket drives the big control above the list.
    private(set) var sockets: [PlugSocket] = []

    /// The printer's own plug, polled fast: it is the thing you are watching.
    let hero = PlugPoller(period: PowerStore.heroCadence)

    // MARK: Cadences

    nonisolated static let heroCadence: Duration = .seconds(5)
    /// Peripheral sockets poll slower — these are background devices, not the thing you are watching.
    nonisolated static let socketCadence: Duration = .seconds(8)

    // MARK: Wiring

    private var client: BambuddyClient?
    private var printerId: Int = 0
    /// True between `start()` and `stop()`. A reload that lands while the section is off screen must
    /// not quietly restart the polls that leaving it stopped.
    private var polling = false

    // MARK: - Session

    /// Point the section at a session: on connect, on a re-Save, and on a printer switch.
    ///
    /// The printer id is part of ATTACHING rather than a separate setter because the printer's own
    /// plug is resolved per printer (`getPlug(printerId)`) — the two arrive together or the store is
    /// briefly asking the wrong question.
    ///
    /// Re-pointing the pollers is not tidiness. While this lived on the view each poller was owned by
    /// a `.task(id:)` keyed ONLY on the plug id, so saving a new base URL or API key left every
    /// poller hammering the OLD client until the plug list happened to change.
    ///
    /// What is on screen is deliberately NOT blanked: `reload()` replaces it one round trip later,
    /// and blanking first makes a switch read as slower than it is.
    func attach(client: BambuddyClient?, printerId: Int) {
        guard client !== self.client || printerId != self.printerId else { return }
        self.client = client
        self.printerId = printerId
        syncPollers()
    }

    // MARK: - Polling

    /// Begin every poll this section owns. Idempotent, and safe before the first `reload()` — a
    /// poller with nothing bound to it simply does not run, and `reload()` starts it when the plug
    /// list lands.
    func start() {
        polling = true
        startPollers()
    }

    /// Stop every poll this section owns.
    ///
    /// iOS calls this when the Power tab goes away and macOS when the section is deselected: a smart
    /// plug read every 5 s on behalf of a screen nobody is looking at is exactly what the old
    /// per-view `.task` lifetime was preventing.
    func stop() {
        polling = false
        hero.stop()
        for socket in sockets { socket.poller.stop() }
    }

    private func startPollers() {
        hero.start()
        for socket in sockets { socket.poller.start() }
    }

    /// Reconcile the pollers with the plug list and the current session.
    private func syncPollers() {
        let client = self.client
        hero.bind(client: client, plugId: plug.value?.id)

        var existing: [Int: PlugPoller] = [:]
        for socket in sockets { existing[socket.plug.id] = socket.poller }

        sockets = Power.otherPlugs(allPlugs, printerPlugId: nil).map { p in
            // Reused BY PLUG ID. A fresh poller would lose `on`, the live numbers and any settle
            // window in flight, so a socket would blink back to "Off" under the user's finger on
            // every reload — which the row's `@State` poller plus `.task(id: plug.id)` used to
            // prevent for free.
            let poller = existing.removeValue(forKey: p.id) ?? PlugPoller(period: Self.socketCadence)
            poller.bind(client: client, plugId: p.id)
            return PlugSocket(plug: p, poller: poller)
        }

        // Whatever is left is a socket that has gone away — deleted server-side, or disabled, which
        // `Power.otherPlugs` filters out. Nothing will ever read it again, so end its loop.
        for gone in existing.values { gone.stop() }

        if polling { startPollers() }
    }

    // MARK: - Loading

    /// What pull-to-refresh and ⌘R call: re-resolve which plug is the printer's, the whole strip, and
    /// the tariff those numbers are priced with.
    func reload() async {
        guard let client else { return }
        async let fetchedPlug = client.getPlug(printerId)
        async let fetchedAll = client.listPlugs()
        async let fetchedSettings = settingsOrNil(client)
        let (p, all, s) = await (fetchedPlug, fetchedAll, fetchedSettings)
        plug = p.map(PlugSlot.linked) ?? .unlinked
        allPlugs = all
        settings = s
        syncPollers()
        // Refreshing the plug list without refreshing the numbers it describes would leave stale
        // watts on screen for the rest of the poll interval.
        await hero.refreshNow()
    }

    // MARK: - Automations

    /// Every automation armed on the printer's own plug.
    var automations: [PlugAutomation] { Power.plugAutomations(plug.value) }

    // MARK: - Money

    /// The electricity price, or nil when the server has none set — which is a different statement
    /// from "it costs nothing", and the UI says so.
    var price: Double? { finiteNumber(settings?.energyCostPerKwh) }

    /// The symbol every money figure in this section is rendered with.
    var symbol: String { Money.symbol(settings?.currency) }

    /// Always two decimals, so a column of costs lines up under tabular figures.
    func money(_ amount: Double) -> String { Money.format(symbol, amount) }

    /// Today's energy, priced.
    var todayCost: Double? {
        guard let price, let kwh = hero.kwh else { return nil }
        return kwh * price
    }

    /// This print's energy cost so far and at completion, extrapolated from the live draw.
    ///
    /// `status` is a parameter rather than store state because the live status lives on `AppModel`
    /// and changes on every socket frame — a copy here would be the stale one.
    func projection(_ status: PrinterStatus?) -> (soFar: Double?, projected: Double?) {
        guard Self.isRunning(status),
              let price,
              let watts = hero.watts,
              let remain = Self.remainingMinutes(status),
              let pct = finiteNumber(status?.progress), pct > 0, pct < 100
        else { return (nil, nil) }
        // total = elapsed + remain and pct = elapsed / total, so elapsed = remain · pct / (100 − pct).
        let elapsed = (remain * pct) / (100 - pct)
        let kwhPerMin = watts / 1000 / 60
        return (elapsed * kwhPerMin * price, (elapsed + remain) * kwhPerMin * price)
    }

    // MARK: - Print state

    /// The printer's OWN `RUNNING` state, which is the question the projection asks: is a print
    /// drawing power right now.
    ///
    /// Deliberately NOT `DashVM.kind == .live`, which is the nearby question "is there an active
    /// job" — it counts a PAUSED print as live, and a paused print's live draw would extrapolate a
    /// cost from a machine that is sitting still.
    nonisolated static func isRunning(_ status: PrinterStatus?) -> Bool {
        (status?.state ?? "").uppercased() == "RUNNING"
    }

    /// Minutes left, when the printer reports a usable number.
    nonisolated static func remainingMinutes(_ status: PrinterStatus?) -> Double? {
        finiteNumber(status?.remainingTime)
    }

    // MARK: - Switching

    /// What a tap on the hero control means. `hero.on` decides the direction, so the caller does not
    /// have to.
    var heroIntent: PlugToggleIntent {
        guard plug.value != nil else { return .ignore }
        return hero.on ? .confirmOff : .apply(true)
    }

    /// What a drag of a socket row's switch means. The toggle already knows which way it was pulled.
    nonisolated static func socketIntent(_ next: Bool) -> PlugToggleIntent {
        next ? .apply(true) : .confirmOff
    }

    /// Surfaces Bambuddy's own `detail` (e.g. "Plug is disabled") instead of transport noise.
    nonisolated static func failureMessage(_ error: Error) -> String {
        if let e = error as? BambuddyError { return "Plug command failed — \(e.detail)" }
        return "Plug command failed — \(error.localizedDescription)"
    }
}

/// The settings read is the only one of the three fetches that throws, and a failure here just
/// means "price unknown", so it is flattened before the concurrent load.
private func settingsOrNil(_ client: BambuddyClient) async -> AppSettings? {
    try? await client.getSettings()
}

#if os(iOS)
import ActivityKit
#endif
import Foundation
import Observation
import SwiftUI

/// Which full-screen surface is up, if any. One enum rather than a pile of booleans, so two
/// overlays can never be open at once.
enum Overlay: Equatable, Hashable {
    case camera
    case upload
    case wizard(LibraryFile)
    case alerts
    case stlViewer(LibraryFile)
    case layerViewer(LibraryFile)
}

/// The app's root state: connection config, the client built from it, the selected printer, live
/// status, and which surface is showing.
///
/// Everything the views read hangs off here so there is a single place that knows how the app is
/// wired together — the equivalent of the RN `Shell`, minus the prop-drilling.
@MainActor
@Observable
final class AppModel {
    // MARK: Configuration

    private(set) var config: AppConfig?
    private(set) var client: BambuddyClient?
    /// nil while the Keychain read is still in flight, so the shell can hold the splash instead of
    /// flashing onboarding at someone who is already set up.
    private(set) var configLoaded = false
    /// True while the app is showing canned data and talking to nothing. Read by the UI to say so
    /// on every screen — a demo that cannot be told from a live connection is a trap, for a
    /// reviewer and for the owner.
    private(set) var isDemo = false

    // MARK: Fleet & status

    private(set) var printers: [Printer] = []
    var printerId: Int = 0 {
        didSet {
            guard printerId != oldValue else { return }
            status?.printerId = printerId
            cooldown?.start(printerId: printerId)
            persist { $0.printerId = self.printerId; $0.printerName = self.printer?.name }
            Task { await refreshLanMode() }
        }
    }

    var printer: Printer? { printers.first { $0.id == printerId } }
    private(set) var status: PrinterStatusStore?

    /// The camera **stream** token — gates the MJPEG stream, snapshots and every thumbnail. Minted
    /// lazily and refreshed on a timer, because it expires after an hour.
    private(set) var cameraToken: String?

    // MARK: Capability gating

    private(set) var lanMode: LanMode = .unknown

    /// Is the current network path metered? Owned here because it is app-wide and long-lived — the
    /// monitor should not start and stop with whichever view happens to care. Today that is the
    /// dashboard camera tile, which picks its frame rate from it (`CameraRate`).
    let networkPath = NetworkPathCost()

    // MARK: Derived surfaces

    private(set) var cooldown: CooldownStore?
    /// iOS only. macOS has no ActivityKit; its equivalent surface is the menu bar extra (§5.1),
    /// which reads `status` directly rather than pushing a card.
    #if os(iOS)
    private(set) var liveActivity: LiveActivityController?
    #endif

    /// Appearance preference. Applied at the root, so a change re-themes the whole tree at once.
    var theme: ThemePreference = .system {
        didSet {
            guard theme != oldValue else { return }
            persist { $0.theme = self.theme.rawValue }
        }
    }

    // MARK: UI state

    var tab: TabKey = .printer
    var overlay: Overlay?
    var toast: String?

    /// Live view-model for the selected printer. Recomputed on every status change, which is cheap:
    /// it is a pure function over a value type.
    var vm: DashVM { Dash.present(status?.status) }

    private var derivedTask: Task<Void, Never>?
    private var cameraTokenTask: Task<Void, Never>?
    private var fleetTask: Task<Void, Never>?
    private var lanTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Set the first time `load()` runs. Now that `AppModel` is owned by the App rather than by one
    /// view, `load()` is no longer reachable exactly once: on macOS several scenes can appear and
    /// disappear over a session, and a window reopening would otherwise re-enter here and call
    /// `connect` on an already-live session — tearing down a working socket to rebuild the same one.
    private var hasLoaded = false

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        var stored = SecureConfig.load()
        // Belt and braces: a demo config must never come back as a real one. `persist` is guarded,
        // but a build that already wrote one (or a future path that forgets) would otherwise strand
        // the owner on a server that does not exist, with no obvious way to tell why.
        if stored?.baseUrl == AppModel.demoBaseUrl {
            SecureConfig.clear()
            stored = nil
        }
        config = stored
        theme = ThemePreference.from(stored?.theme)
        configLoaded = true
        if let stored, stored.isComplete { await connect(stored) }
    }

    /// Build the client and start everything that depends on it.
    ///
    /// Re-entrant by design: Settings → Save calls this on an already-connected app, so the previous
    /// session has to be torn down FIRST. Assigning over `status`/`cooldown` does not stop them —
    /// each is pinned by its own running task — so every Save used to add a live WebSocket and two
    /// poll loops that nothing could ever reach again, still using the old base URL and API key.
    func connect(_ cfg: AppConfig) async {
        teardownSession()

        config = cfg
        SecureConfig.save(cfg)

        let c = BambuddyClient(
            baseUrl: cfg.baseUrl,
            apiKey: cfg.apiKey,
            adminUsername: cfg.adminUsername,
            adminPassword: cfg.adminPassword
        )
        client = c

        // Restore the last printer immediately so the first paint is the right machine; the fleet
        // refresh below corrects it if that printer is gone. Safe here only because `teardownSession`
        // already cleared the stores — the `didSet` reaches for them, and reaching for the PREVIOUS
        // session's stores is how a re-Save used to restart the very loop it was about to orphan.
        printerId = cfg.printerId ?? 0
        cameraToken = cfg.cameraToken

        let store = PrinterStatusStore(client: c, printerId: printerId)
        status = store
        store.start()

        let cool = CooldownStore(client: c)
        cooldown = cool
        cool.start(printerId: printerId)

        #if os(iOS)
        liveActivity = LiveActivityController(config: cfg)

        // Remote notifications: the device token feeds the alert banners this app has never been
        // able to receive, and it is the only token kind Apple delivers a silent push to — which
        // makes it the only one the relay can vouch. Wired here rather than at launch because it
        // needs the configured server to register against.
        PushAppDelegate.onDeviceToken = { [weak self] token in
            Task { @MainActor in self?.liveActivity?.registerDeviceToken(token) }
        }
        PushAppDelegate.onVouchNonce = { [weak self] nonce in
            Task { @MainActor in
                guard let controller = self?.liveActivity else { return }
                for token in controller.deviceTokens { controller.vouchNonceArrived(nonce, for: token) }
            }
        }
        Task { await PushRegistrar().start() }
        #endif

        startFleetRefresh()
        startCameraTokenRefresh()
        startDerivedRefresh()
        await refreshLanMode()
        startLanModeRefresh()
    }

    /// Start a demo session: canned data, no server, nothing persisted.
    ///
    /// Deliberately does NOT call `SecureConfig.save` — a demo must not overwrite real credentials,
    /// and must not survive a relaunch as if it were a configured server. Leaving is `signOut`,
    /// which already tears everything down and returns to the config gate.
    ///
    /// The base URL is a placeholder that is never dialled: every request is answered by
    /// `DemoServer` inside the client's transport. It still has to parse as a URL, because the real
    /// URL builder runs — which is the point.
    /// The placeholder host a demo session claims. Never dialled — every request is answered inside
    /// the client — but it has to parse as a URL because the real URL builder runs.
    static let demoBaseUrl = "https://demo.invalid"

    func startDemo() async {
        teardownSession()
        isDemo = true
        let cfg = AppConfig(baseUrl: AppModel.demoBaseUrl, apiKey: "demo")
        config = cfg
        let c = BambuddyClient(baseUrl: cfg.baseUrl, apiKey: cfg.apiKey, demo: DemoServer())
        client = c
        printerId = 1
        cameraToken = nil
        // `.lan` would offer LAN-only controls that cannot work here; `.unknown` leaves the gates
        // that already exist to explain themselves, which is the honest state for "no printer".
        lanMode = .unknown

        // The same stores the real session uses. The status store's socket attempt fails (the demo
        // refuses to mint a ws token) and it falls back to its REST poll, which the demo DOES
        // answer — so the print advances on screen through the app's own polling path.
        let store = PrinterStatusStore(client: c, printerId: printerId)
        status = store
        store.start()

        printers = (try? await c.listPrinters()) ?? []
    }

    /// Leave the demo and go back to whatever the owner actually had.
    ///
    /// NOT `signOut`. That clears the Keychain, which is right when someone deliberately
    /// disconnects and catastrophic when they were only looking at the demo — entering it from a
    /// configured app and leaving would have destroyed the base URL and API key they had typed in
    /// once and never wanted to type again.
    func exitDemo() async {
        guard isDemo else { return }
        teardownSession()
        isDemo = false
        client = nil
        printers = []
        if let stored = SecureConfig.load(), stored.isComplete {
            await connect(stored)
        } else {
            config = nil        // nothing to go back to: the config gate, not a broken session
        }
    }

    func signOut() {
        isDemo = false

        #if os(iOS)
        endLiveActivities()
        #endif
        teardownSession()
        #if os(iOS)
        liveActivity = nil
        #endif
        client = nil
        printers = []
        cameraToken = nil
        lanMode = .unknown
        SecureConfig.clear()
        config = nil
    }

    /// Stop everything the current client owns. Both stores keep themselves alive from inside their
    /// own loops, so dropping the reference is not a teardown — `stop()` is.
    private func teardownSession() {
        status?.stop()
        status = nil
        cooldown?.stop()
        cooldown = nil
        derivedTask?.cancel()
        derivedTask = nil
        cameraTokenTask?.cancel()
        cameraTokenTask = nil
        fleetTask?.cancel()
        fleetTask = nil
        lanTask?.cancel()
        lanTask = nil
    }

    /// End every live card on the way out of a session.
    ///
    /// Sign-out cancels the reconcile loop and clears the config, so nothing will ever update or end
    /// these again — not even the next launch, since `sync` needs a status and a status needs a
    /// client. A card left up ticks toward a stale ETA until ActivityKit expires it hours later.
    ///
    /// Enumerating ActivityKit rather than the printers we happen to have synced is deliberate: a
    /// card can outlive the fleet entry that created it, and the attributes it carries are exactly
    /// what `end` keys on.
    #if os(iOS)
    private func endLiveActivities() {
        guard let la = liveActivity else { return }
        let cards = Activity<PrintActivityAttributes>.activities
            .map { ($0.attributes.printerId, $0.attributes.amsId) }
        guard !cards.isEmpty else { return }
        Task {
            for (printerId, amsId) in cards {
                await la.end(printerId: printerId, amsId: amsId)
            }
        }
    }
    #endif

    // MARK: - Fleet

    /// Refresh the printer list every 30 s and heal a selection that has gone away.
    private func startFleetRefresh() {
        fleetTask?.cancel()
        fleetTask = Task { [weak self] in
            var consecutiveMisses = 0
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                if let list = try? await client.listPrinters() {
                    self.printers = list
                    consecutiveMisses = self.reconcileSelection(list, misses: consecutiveMisses)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Adopt the first printer immediately when the current id was never confirmed (a fresh connect
    /// or a guessed default), but heal a previously-confirmed-then-vanished id only on the SECOND
    /// consecutive miss — a single bad fleet response should not bounce the user to another machine.
    private func reconcileSelection(_ list: [Printer], misses: Int) -> Int {
        guard !list.isEmpty else { return misses }
        if list.contains(where: { $0.id == printerId }) { return 0 }
        let neverConfirmed = config?.printerId == nil || printerId == 0
        if neverConfirmed {
            printerId = list[0].id
            return 0
        }
        if misses >= 1 {
            printerId = list[0].id
            return 0
        }
        return misses + 1
    }

    /// Recompute the cooldown readout and reconcile Live Activity cards against live status.
    ///
    /// One loop rather than an observer on `status`: both consumers are cheap but neither wants to
    /// run on every socket frame, and a fixed cadence is easier to reason about than change-driven
    /// re-entry.
    private func startDerivedRefresh() {
        derivedTask?.cancel()
        derivedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // The cooldown card is a property of the machine the user is LOOKING at, so it stays
                // on the selection.
                let selected = self.status?.status
                let material = self.vm.ams.first { $0.active }?.label
                self.cooldown?.update(status: selected, vmKind: self.vm.kind, material: material)

                // Live Activities are not: a card belongs to a printer, and this is the only thing
                // that will ever call `sync` for one. Reconciling the selection alone froze the other
                // machine's card the moment the user switched — and left it up for good, since
                // nothing would then be called with that printer's id to end it.
                #if os(iOS)
                for (id, s) in self.status?.statuses ?? [:] {
                    await self.liveActivity?.sync(
                        printerId: id,
                        printerName: self.printers.first { $0.id == id }?.name ?? "",
                        vm: Dash.present(s),
                        status: s
                    )
                }
                #endif
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: - Camera token

    /// Mint a camera token now and re-mint every 45 minutes. The server's TTL is an hour; refreshing
    /// early means a long-lived session never shows a 401'd thumbnail.
    private func startCameraTokenRefresh() {
        cameraTokenTask?.cancel()
        cameraTokenTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                if let token = try? await client.mintCameraToken() {
                    self.cameraToken = token
                    self.persist { $0.cameraToken = token }
                }
                try? await Task.sleep(for: .seconds(45 * 60))
            }
        }
    }

    // MARK: - LAN Developer Mode

    /// Deliberately an out-of-band REST read: the WebSocket frame omits `developerMode` entirely, so
    /// reading it from live status would report `unknown` forever.
    func refreshLanMode() async {
        guard let client else { return }
        guard let s = try? await client.getStatus(printerId) else { return }  // keep the last value on failure
        lanMode = Lan.mode(from: s)
    }

    private func startLanModeRefresh() {
        lanTask?.cancel()
        lanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                await self?.refreshLanMode()
            }
        }
    }

    // MARK: - Config persistence

    private func persist(_ mutate: (inout AppConfig) -> Void) {
        guard var cfg = config else { return }
        mutate(&cfg)
        config = cfg
        // NEVER write a demo session to the Keychain. `printerId` and `theme` both persist through
        // here on `didSet`, so simply selecting the demo printer was enough to overwrite the owner's
        // real base URL and API key with `demo.invalid` — and on the next launch the app restored
        // that as a genuine server and sat on "Connecting" forever. The demo is a session, not a
        // configuration; the only place that may enforce it is this one chokepoint.
        guard !isDemo else { return }
        SecureConfig.save(cfg)
    }

    func update(_ mutate: (inout AppConfig) -> Void) {
        persist(mutate)
    }

    // MARK: - Actions

    /// Run a printer command, surfacing the server's own message on failure.
    func perform(_ label: String, _ work: @escaping @Sendable (BambuddyClient, Int) async throws -> Void) {
        guard let client else { return }
        let id = printerId
        Task {
            do {
                try await work(client, id)
            } catch let e as BambuddyError {
                toast = "\(label) failed — \(e.detail)"
            } catch {
                toast = "\(label) failed — \(error.localizedDescription)"
            }
        }
    }
}

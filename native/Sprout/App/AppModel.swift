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

    // MARK: Fleet & status

    private(set) var printers: [Printer] = []
    var printerId: Int = 0 {
        didSet {
            guard printerId != oldValue else { return }
            status?.printerId = printerId
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

    // MARK: UI state

    var tab: TabKey = .printer
    var overlay: Overlay?
    var toast: String?

    /// Live view-model for the selected printer. Recomputed on every status change, which is cheap:
    /// it is a pure function over a value type.
    var vm: DashVM { Dash.present(status?.status) }

    private var cameraTokenTask: Task<Void, Never>?
    private var fleetTask: Task<Void, Never>?
    private var lanTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func load() async {
        let stored = SecureConfig.load()
        config = stored
        configLoaded = true
        if let stored, stored.isComplete { await connect(stored) }
    }

    /// Build the client and start everything that depends on it.
    func connect(_ cfg: AppConfig) async {
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
        // refresh below corrects it if that printer is gone.
        printerId = cfg.printerId ?? 0
        cameraToken = cfg.cameraToken

        let store = PrinterStatusStore(client: c, printerId: printerId)
        status = store
        store.start()

        startFleetRefresh()
        startCameraTokenRefresh()
        await refreshLanMode()
        startLanModeRefresh()
    }

    func signOut() {
        status?.stop()
        cameraTokenTask?.cancel()
        fleetTask?.cancel()
        lanTask?.cancel()
        status = nil
        client = nil
        printers = []
        cameraToken = nil
        SecureConfig.clear()
        config = nil
    }

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

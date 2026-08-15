import Foundation
import Observation

/// Which of the Hardware section's three panes is showing.
///
/// Deliberately the SAME enum `HardwareTriage` tags its items with, not a second one that happens to
/// have the same three cases. The triage card's "tap to go there" writes `triage.first?.segment`
/// straight into the selection, and the picker's warning dots come from `HardwareTriage.flagged` —
/// a parallel enum would need a mapping between the two, and a mapping is somewhere for them to
/// disagree.
typealias HardwareSegment = HardwareTriage.Segment

/// Loading / failed / loaded, spelled out. The RN original used a `T | null | undefined` tri-state
/// here and the three branches drive genuinely different UI.
enum MaintLoad {
    case loading
    case failed
    case loaded(MaintenancePrinter)
}

/// The **Hardware** section's data layer: the spool assignments behind the filament slots, the
/// service reminders, and which of the three panes is selected.
///
/// Both view trees drive this one store — `Views/AmsView` on iOS, `Views/Mac/Sections` on macOS —
/// so a fetch, a failure rule or the selection can only be written once. See
/// `docs/native-rewrite/18-mac-port-architecture.md`.
///
/// Topology comes from `AmsTopology` (via `DashVM`) and drying from `Dryer`; nothing here re-derives
/// either. The two things Hardware fetches for itself are spool assignments and maintenance — trays,
/// temperatures, nozzles and the drying countdown are live WebSocket state and need no refetch,
/// which is why `reload()` touches Filament and Service and leaves Nozzles alone.
@Observable
@MainActor
final class HardwareStore {

    // MARK: - What is on screen

    /// nil while the first assignment fetch is in flight. The client swallows its own errors and
    /// returns `[]`, so an empty array means "no spools mapped", never "the fetch failed" — either
    /// way the slot cards degrade to status-only tray data.
    private(set) var assigns: [SlotAssignment]?

    private(set) var maint: MaintLoad = .loading

    /// Maintenance item currently being marked done.
    private(set) var maintBusy: Int?

    /// Which segment is showing.
    ///
    /// Here rather than in a view because two view trees select it, because `⌘R` has to know which
    /// pane is up, and because the dashboard's maintenance chip deep-links into it — that last one
    /// is app-wide by nature and was the reason the handoff spec wanted the selection lifted out of
    /// the screen in the first place.
    var segment: HardwareSegment = .filament

    // MARK: - Session

    private var client: BambuddyClient?
    private var printerId = 0
    private var loadTask: Task<Void, Never>?

    init() {}

    /// Point the store at the current session. Records only — it does not fetch, so the caller
    /// decides when: iOS drives it from the screen's `.task(id:)`, macOS from `start()`.
    ///
    /// Deliberately does NOT clear `assigns` or `maint` when the printer changes. The previous
    /// printer's cards stay on screen until the replacement lands, which is the same
    /// keep-what-is-there rule the failure paths follow — a blank pane reads as slower than the
    /// request is.
    func attach(client: BambuddyClient?, printerId: Int) {
        self.client = client
        self.printerId = printerId
    }

    /// The one-shot load this section needs.
    ///
    /// There is no poller here, and that is not an omission: everything that changes second to
    /// second on Hardware arrives on the WebSocket. Only the two fetched things are worth a
    /// request, and both are fetched on entry.
    func start() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.reload() }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Loading

    /// Everything this section can refetch — and only that. This is what `⌘R` and the Filament
    /// pane's pull-to-refresh call.
    ///
    /// Maintenance is refetched from the Filament pane too, because the triage card is pinned above
    /// the picker on every segment: an overdue service item has to be legible without switching to
    /// Service to find out about it.
    func reload() async {
        guard let client else { return }
        let id = printerId
        async let spools = client.listAssignments(printerId: id)
        async let maintenance = fetchMaintenance(client, id)
        let (loadedSpools, loadedMaintenance) = await (spools, maintenance)
        assigns = loadedSpools
        maint = loadedMaintenance
    }

    func reloadMaintenance() async {
        guard let client else { return }
        maint = .loading
        maint = await fetchMaintenance(client, printerId)
    }

    /// What a refresh gesture means on each pane.
    ///
    /// Nozzles is the case worth writing down: it is live socket state, so there is genuinely
    /// nothing to refetch — the pane just re-renders. Encoded here rather than left to each view
    /// tree to remember, because "refresh the section" and "refresh what this pane can fetch" are
    /// two different questions and only one of them has an answer for Nozzles.
    func refresh(_ segment: HardwareSegment) async {
        switch segment {
        case .filament: await reload()
        case .nozzles:  break
        case .service:  await reloadMaintenance()
        }
    }

    /// Mark a service item done — resets its counter, then refetches so the list re-sorts.
    ///
    /// Returns nil on success, or the message to show when it failed: Bambuddy's own message ("AMS
    /// is busy" from a 409), not the transport noise around it. The caller presents it, because the
    /// two view trees have different alert plumbing.
    func markDone(_ item: MaintenanceItem) async -> String? {
        guard let client else { return nil }
        maintBusy = item.id
        var failure: String?
        do {
            try await client.performMaintenance(item.id)
            await reloadMaintenance()
        } catch {
            failure = (error as? BambuddyError)?.detail ?? error.localizedDescription
        }
        maintBusy = nil
        return failure
    }

    // MARK: - Derived

    /// The service reminders behind the current load state — `[]` while loading and after a failure.
    /// The triage card counts problems it can prove, so an unknown state must read as "nothing to
    /// say" rather than as "nothing wrong".
    var maintenanceItems: [MaintenanceItem] {
        if case .loaded(let data) = maint { return data.maintenanceItems }
        return []
    }

    /// Due first, then warnings, then by how soon each falls due.
    var serviceItems: [MaintenanceItem] {
        maintenanceItems
            .filter { $0.enabled ?? false }
            .sorted { a, b in
                if (a.isDue ?? false) != (b.isDue ?? false) { return a.isDue ?? false }
                if (a.isWarning ?? false) != (b.isWarning ?? false) { return a.isWarning ?? false }
                return (a.hoursUntilDue?.double ?? 0) < (b.hoursUntilDue?.double ?? 0)
            }
    }

    /// The inventory spool bound to a slot. Prefer `trayUuid` (RFID); fall back to (unit, LOCAL tray).
    ///
    /// Assignments are stored per (ams_id, LOCAL tray_id), so matching on the tray id alone would
    /// resolve the HT's spool to AMS-0's — both units have a tray 0.
    func spool(for slot: AmsSlotVM, status: PrinterStatus?) -> Spool? {
        guard let assigns, !assigns.isEmpty else { return nil }
        let uuid = status?.ams?
            .first { $0.id == slot.unitId }?
            .tray?.first { $0.id == slot.localId }?
            .trayUuid
        if let uuid, !uuid.isEmpty, let hit = assigns.first(where: { $0.spool.trayUuid == uuid }) {
            return hit.spool
        }
        return assigns.first { $0.amsId == slot.unitId && $0.trayId == slot.localId }?.spool
    }
}

/// Off-actor so the two fetches in `reload()` genuinely overlap. A failure becomes `.failed` rather
/// than an empty printer: "couldn't load maintenance" and "this printer has no reminders set up" are
/// different sentences and the section says both.
private func fetchMaintenance(_ client: BambuddyClient, _ printerId: Int) async -> MaintLoad {
    do { return .loaded(try await client.getMaintenance(printerId)) } catch { return .failed }
}
